unit RM.Vulkan.Loader;

// Loads only the system Vulkan driver loader. No SDK/runtime is redistributed.
interface

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils, RM.Vulkan.Bindings;

type
  EVulkanError = class(Exception);

  TVulkanAPI = class
  private
    FLibrary: NativeUInt;
    function InstanceProc(Instance: VkInstance; const Name: AnsiString): Pointer;
    function DeviceProc(Device: VkDevice; const Name: AnsiString): Pointer;
  public
    vkGetInstanceProcAddr: PFN_vkGetInstanceProcAddr;
    vkGetDeviceProcAddr: PFN_vkGetDeviceProcAddr;
    vkCreateInstance: PFN_vkCreateInstance;
    vkDestroyInstance: PFN_vkDestroyInstance;
    vkEnumeratePhysicalDevices: PFN_vkEnumeratePhysicalDevices;
    vkGetPhysicalDeviceProperties2: PFN_vkGetPhysicalDeviceProperties2;
    vkGetPhysicalDeviceQueueFamilyProperties: PFN_vkGetPhysicalDeviceQueueFamilyProperties;
    vkGetPhysicalDeviceMemoryProperties: PFN_vkGetPhysicalDeviceMemoryProperties;
    vkEnumerateDeviceExtensionProperties: PFN_vkEnumerateDeviceExtensionProperties;
    vkGetPhysicalDeviceImageFormatProperties2: PFN_vkGetPhysicalDeviceImageFormatProperties2;
    vkCreateDevice: PFN_vkCreateDevice;
    vkDestroyDevice: PFN_vkDestroyDevice;
    vkGetDeviceQueue: PFN_vkGetDeviceQueue;
    vkCreateImage: PFN_vkCreateImage;
    vkDestroyImage: PFN_vkDestroyImage;
    vkGetImageMemoryRequirements: PFN_vkGetImageMemoryRequirements;
    vkGetMemoryWin32HandlePropertiesKHR: PFN_vkGetMemoryWin32HandlePropertiesKHR;
    vkGetMemoryFdKHR: PFN_vkGetMemoryFdKHR;
    vkCreateSemaphore: PFN_vkCreateSemaphore;
    vkDestroySemaphore: PFN_vkDestroySemaphore;
    vkGetSemaphoreFdKHR: PFN_vkGetSemaphoreFdKHR;
    vkGetPhysicalDeviceExternalSemaphoreProperties: PFN_vkGetPhysicalDeviceExternalSemaphoreProperties;
    vkImportSemaphoreFdKHR: PFN_vkImportSemaphoreFdKHR;
    vkGetAndroidHardwareBufferPropertiesANDROID: PFN_vkGetAndroidHardwareBufferPropertiesANDROID;
    vkAllocateMemory: PFN_vkAllocateMemory;
    vkFreeMemory: PFN_vkFreeMemory;
    vkBindImageMemory: PFN_vkBindImageMemory;
    vkCreateImageView: PFN_vkCreateImageView;
    vkDestroyImageView: PFN_vkDestroyImageView;
    vkCreateRenderPass: PFN_vkCreateRenderPass;
    vkDestroyRenderPass: PFN_vkDestroyRenderPass;
    vkCreateFramebuffer: PFN_vkCreateFramebuffer;
    vkDestroyFramebuffer: PFN_vkDestroyFramebuffer;
    vkCreateShaderModule: PFN_vkCreateShaderModule;
    vkDestroyShaderModule: PFN_vkDestroyShaderModule;
    vkCreatePipelineLayout: PFN_vkCreatePipelineLayout;
    vkDestroyPipelineLayout: PFN_vkDestroyPipelineLayout;
    vkCreateGraphicsPipelines: PFN_vkCreateGraphicsPipelines;
    vkDestroyPipeline: PFN_vkDestroyPipeline;
    vkCreateCommandPool: PFN_vkCreateCommandPool;
    vkDestroyCommandPool: PFN_vkDestroyCommandPool;
    vkAllocateCommandBuffers: PFN_vkAllocateCommandBuffers;
    vkResetCommandBuffer: PFN_vkResetCommandBuffer;
    vkBeginCommandBuffer: PFN_vkBeginCommandBuffer;
    vkEndCommandBuffer: PFN_vkEndCommandBuffer;
    vkCmdPipelineBarrier: PFN_vkCmdPipelineBarrier;
    vkCmdBeginRenderPass: PFN_vkCmdBeginRenderPass;
    vkCmdEndRenderPass: PFN_vkCmdEndRenderPass;
    vkCmdBindPipeline: PFN_vkCmdBindPipeline;
    vkCmdPushConstants: PFN_vkCmdPushConstants;
    vkCmdSetViewport: PFN_vkCmdSetViewport;
    vkCmdSetScissor: PFN_vkCmdSetScissor;
    vkCmdDraw: PFN_vkCmdDraw;
    vkCreateFence: PFN_vkCreateFence;
    vkDestroyFence: PFN_vkDestroyFence;
    vkResetFences: PFN_vkResetFences;
    vkWaitForFences: PFN_vkWaitForFences;
    vkQueueSubmit: PFN_vkQueueSubmit;
    vkDeviceWaitIdle: PFN_vkDeviceWaitIdle;
    // Compute
    vkEnumerateInstanceVersion: PFN_vkEnumerateInstanceVersion;
    vkGetPhysicalDeviceProperties: PFN_vkGetPhysicalDeviceProperties;
    vkGetPhysicalDeviceFeatures2: PFN_vkGetPhysicalDeviceFeatures2;
    vkCreateBuffer: PFN_vkCreateBuffer;
    vkDestroyBuffer: PFN_vkDestroyBuffer;
    vkGetBufferMemoryRequirements: PFN_vkGetBufferMemoryRequirements;
    vkBindBufferMemory: PFN_vkBindBufferMemory;
    vkMapMemory: PFN_vkMapMemory;
    vkUnmapMemory: PFN_vkUnmapMemory;
    vkFlushMappedMemoryRanges: PFN_vkFlushMappedMemoryRanges;
    vkInvalidateMappedMemoryRanges: PFN_vkInvalidateMappedMemoryRanges;
    vkCreateDescriptorSetLayout: PFN_vkCreateDescriptorSetLayout;
    vkDestroyDescriptorSetLayout: PFN_vkDestroyDescriptorSetLayout;
    vkCreateDescriptorPool: PFN_vkCreateDescriptorPool;
    vkDestroyDescriptorPool: PFN_vkDestroyDescriptorPool;
    vkResetDescriptorPool: PFN_vkResetDescriptorPool;
    vkAllocateDescriptorSets: PFN_vkAllocateDescriptorSets;
    vkFreeDescriptorSets: PFN_vkFreeDescriptorSets;
    vkUpdateDescriptorSets: PFN_vkUpdateDescriptorSets;
    vkCreateComputePipelines: PFN_vkCreateComputePipelines;
    vkCmdBindDescriptorSets: PFN_vkCmdBindDescriptorSets;
    vkCmdDispatch: PFN_vkCmdDispatch;
    vkCmdDispatchIndirect: PFN_vkCmdDispatchIndirect;
    vkCmdCopyBuffer: PFN_vkCmdCopyBuffer;
    vkCmdFillBuffer: PFN_vkCmdFillBuffer;
    vkCmdUpdateBuffer: PFN_vkCmdUpdateBuffer;
    vkFreeCommandBuffers: PFN_vkFreeCommandBuffers;
    vkResetCommandPool: PFN_vkResetCommandPool;
    vkGetFenceStatus: PFN_vkGetFenceStatus;
    vkQueueWaitIdle: PFN_vkQueueWaitIdle;
    vkCreateQueryPool: PFN_vkCreateQueryPool;
    vkDestroyQueryPool: PFN_vkDestroyQueryPool;
    vkCmdResetQueryPool: PFN_vkCmdResetQueryPool;
    vkCmdWriteTimestamp: PFN_vkCmdWriteTimestamp;
    vkGetQueryPoolResults: PFN_vkGetQueryPoolResults;
    // Graphics rendering into images
    vkGetPhysicalDeviceFormatProperties: PFN_vkGetPhysicalDeviceFormatProperties;
    vkCreateSampler: PFN_vkCreateSampler;
    vkDestroySampler: PFN_vkDestroySampler;
    vkCmdBindVertexBuffers: PFN_vkCmdBindVertexBuffers;
    vkCmdCopyBufferToImage: PFN_vkCmdCopyBufferToImage;
    vkCmdCopyImageToBuffer: PFN_vkCmdCopyImageToBuffer;
    vkCmdBlitImage: PFN_vkCmdBlitImage;
    vkCmdCopyImage: PFN_vkCmdCopyImage;
    vkCmdSetBlendConstants: PFN_vkCmdSetBlendConstants;
    vkCmdSetStencilReference: PFN_vkCmdSetStencilReference;
    vkCmdSetStencilCompareMask: PFN_vkCmdSetStencilCompareMask;
    vkCmdSetStencilWriteMask: PFN_vkCmdSetStencilWriteMask;
    vkCmdClearAttachments: PFN_vkCmdClearAttachments;
    // Vulkan 1.2 (nil on 1.1 devices)
    vkWaitSemaphores: PFN_vkWaitSemaphores;
    vkSignalSemaphore: PFN_vkSignalSemaphore;
    vkGetSemaphoreCounterValue: PFN_vkGetSemaphoreCounterValue;
    constructor Create;
    destructor Destroy; override;
    procedure LoadInstance(Instance: VkInstance);
    procedure LoadDevice(Device: VkDevice);
  end;

procedure CheckVulkan(ResultCode: VkResult; const Operation: string);

implementation

procedure CheckVulkan(ResultCode: VkResult; const Operation: string);
begin
  if ResultCode <> VK_SUCCESS then
    raise EVulkanError.CreateFmt('%s failed (VkResult %d).', [Operation, ResultCode]);
end;

constructor TVulkanAPI.Create;
begin
  inherited;
  {$IFDEF MSWINDOWS}
  FLibrary := LoadLibraryEx('vulkan-1.dll', 0, $00000800); // LOAD_LIBRARY_SEARCH_SYSTEM32
  {$ELSEIF Defined(ANDROID)}
  FLibrary := LoadLibrary('libvulkan.so');
  {$ELSEIF Defined(LINUX)}
  FLibrary := LoadLibrary('libvulkan.so.1');
  {$ELSE}
  {$MESSAGE FATAL 'This Vulkan loader supports Windows, Linux and Android.'}
  {$ENDIF}
  if FLibrary = 0 then
    raise EVulkanError.Create('The system Vulkan loader is unavailable. Install a Vulkan-capable GPU driver.');
  vkGetInstanceProcAddr := PFN_vkGetInstanceProcAddr(GetProcAddress(FLibrary, 'vkGetInstanceProcAddr'));
  if not Assigned(vkGetInstanceProcAddr) then
    raise EVulkanError.Create('The system Vulkan loader has no vkGetInstanceProcAddr.');
  vkCreateInstance := PFN_vkCreateInstance(InstanceProc(nil, 'vkCreateInstance'));
  vkEnumerateInstanceVersion := PFN_vkEnumerateInstanceVersion(vkGetInstanceProcAddr(nil, 'vkEnumerateInstanceVersion'));
end;

destructor TVulkanAPI.Destroy;
begin
  if FLibrary <> 0 then
    FreeLibrary(FLibrary);
  inherited;
end;

function TVulkanAPI.InstanceProc(Instance: VkInstance; const Name: AnsiString): Pointer;
begin
  Result := Pointer(vkGetInstanceProcAddr(Instance, PAnsiChar(Name)));
  if Result = nil then
    raise EVulkanError.Create('Missing Vulkan instance function: ' + string(Name));
end;

function TVulkanAPI.DeviceProc(Device: VkDevice; const Name: AnsiString): Pointer;
begin
  Result := Pointer(vkGetDeviceProcAddr(Device, PAnsiChar(Name)));
  if Result = nil then
    raise EVulkanError.Create('Missing Vulkan device function: ' + string(Name));
end;

procedure TVulkanAPI.LoadInstance(Instance: VkInstance);
begin
  vkDestroyInstance := PFN_vkDestroyInstance(InstanceProc(Instance, 'vkDestroyInstance'));
  vkEnumeratePhysicalDevices := PFN_vkEnumeratePhysicalDevices(InstanceProc(Instance, 'vkEnumeratePhysicalDevices'));
  vkGetPhysicalDeviceProperties2 := PFN_vkGetPhysicalDeviceProperties2(InstanceProc(Instance, 'vkGetPhysicalDeviceProperties2'));
  vkGetPhysicalDeviceQueueFamilyProperties := PFN_vkGetPhysicalDeviceQueueFamilyProperties(InstanceProc(Instance, 'vkGetPhysicalDeviceQueueFamilyProperties'));
  vkGetPhysicalDeviceMemoryProperties := PFN_vkGetPhysicalDeviceMemoryProperties(InstanceProc(Instance, 'vkGetPhysicalDeviceMemoryProperties'));
  vkEnumerateDeviceExtensionProperties := PFN_vkEnumerateDeviceExtensionProperties(InstanceProc(Instance, 'vkEnumerateDeviceExtensionProperties'));
  vkGetPhysicalDeviceImageFormatProperties2 := PFN_vkGetPhysicalDeviceImageFormatProperties2(InstanceProc(Instance, 'vkGetPhysicalDeviceImageFormatProperties2'));
  vkCreateDevice := PFN_vkCreateDevice(InstanceProc(Instance, 'vkCreateDevice'));
  vkGetDeviceProcAddr := PFN_vkGetDeviceProcAddr(InstanceProc(Instance, 'vkGetDeviceProcAddr'));
  vkGetPhysicalDeviceProperties := PFN_vkGetPhysicalDeviceProperties(InstanceProc(Instance, 'vkGetPhysicalDeviceProperties'));
  vkGetPhysicalDeviceFeatures2 := PFN_vkGetPhysicalDeviceFeatures2(InstanceProc(Instance, 'vkGetPhysicalDeviceFeatures2'));
  vkGetPhysicalDeviceFormatProperties := PFN_vkGetPhysicalDeviceFormatProperties(
    InstanceProc(Instance, 'vkGetPhysicalDeviceFormatProperties'));
  {$IF Defined(LINUX) or Defined(ANDROID)}
  vkGetPhysicalDeviceExternalSemaphoreProperties := PFN_vkGetPhysicalDeviceExternalSemaphoreProperties(
    InstanceProc(Instance, 'vkGetPhysicalDeviceExternalSemaphoreProperties'));
  {$ENDIF}
end;

// Extension functions are nil when the device was created without the extension.
procedure TVulkanAPI.LoadDevice(Device: VkDevice);
begin
  vkDestroyDevice := PFN_vkDestroyDevice(DeviceProc(Device, 'vkDestroyDevice'));
  vkGetDeviceQueue := PFN_vkGetDeviceQueue(DeviceProc(Device, 'vkGetDeviceQueue'));
  vkCreateImage := PFN_vkCreateImage(DeviceProc(Device, 'vkCreateImage'));
  vkDestroyImage := PFN_vkDestroyImage(DeviceProc(Device, 'vkDestroyImage'));
  vkGetImageMemoryRequirements := PFN_vkGetImageMemoryRequirements(DeviceProc(Device, 'vkGetImageMemoryRequirements'));
  {$IFDEF MSWINDOWS}
  vkGetMemoryWin32HandlePropertiesKHR := PFN_vkGetMemoryWin32HandlePropertiesKHR(vkGetDeviceProcAddr(Device, 'vkGetMemoryWin32HandlePropertiesKHR'));
  {$ELSEIF Defined(LINUX) or Defined(ANDROID)}
  vkCreateSemaphore := PFN_vkCreateSemaphore(DeviceProc(Device, 'vkCreateSemaphore'));
  vkDestroySemaphore := PFN_vkDestroySemaphore(DeviceProc(Device, 'vkDestroySemaphore'));
  vkGetSemaphoreFdKHR := PFN_vkGetSemaphoreFdKHR(vkGetDeviceProcAddr(Device, 'vkGetSemaphoreFdKHR'));
  {$IFDEF ANDROID}
  vkImportSemaphoreFdKHR := PFN_vkImportSemaphoreFdKHR(vkGetDeviceProcAddr(Device, 'vkImportSemaphoreFdKHR'));
  vkGetAndroidHardwareBufferPropertiesANDROID := PFN_vkGetAndroidHardwareBufferPropertiesANDROID(
    vkGetDeviceProcAddr(Device, 'vkGetAndroidHardwareBufferPropertiesANDROID'));
  {$ELSE}
  vkGetMemoryFdKHR := PFN_vkGetMemoryFdKHR(vkGetDeviceProcAddr(Device, 'vkGetMemoryFdKHR'));
  {$ENDIF}
  {$ENDIF}
  vkAllocateMemory := PFN_vkAllocateMemory(DeviceProc(Device, 'vkAllocateMemory'));
  vkFreeMemory := PFN_vkFreeMemory(DeviceProc(Device, 'vkFreeMemory'));
  vkBindImageMemory := PFN_vkBindImageMemory(DeviceProc(Device, 'vkBindImageMemory'));
  vkCreateImageView := PFN_vkCreateImageView(DeviceProc(Device, 'vkCreateImageView'));
  vkDestroyImageView := PFN_vkDestroyImageView(DeviceProc(Device, 'vkDestroyImageView'));
  vkCreateRenderPass := PFN_vkCreateRenderPass(DeviceProc(Device, 'vkCreateRenderPass'));
  vkDestroyRenderPass := PFN_vkDestroyRenderPass(DeviceProc(Device, 'vkDestroyRenderPass'));
  vkCreateFramebuffer := PFN_vkCreateFramebuffer(DeviceProc(Device, 'vkCreateFramebuffer'));
  vkDestroyFramebuffer := PFN_vkDestroyFramebuffer(DeviceProc(Device, 'vkDestroyFramebuffer'));
  vkCreateShaderModule := PFN_vkCreateShaderModule(DeviceProc(Device, 'vkCreateShaderModule'));
  vkDestroyShaderModule := PFN_vkDestroyShaderModule(DeviceProc(Device, 'vkDestroyShaderModule'));
  vkCreatePipelineLayout := PFN_vkCreatePipelineLayout(DeviceProc(Device, 'vkCreatePipelineLayout'));
  vkDestroyPipelineLayout := PFN_vkDestroyPipelineLayout(DeviceProc(Device, 'vkDestroyPipelineLayout'));
  vkCreateGraphicsPipelines := PFN_vkCreateGraphicsPipelines(DeviceProc(Device, 'vkCreateGraphicsPipelines'));
  vkDestroyPipeline := PFN_vkDestroyPipeline(DeviceProc(Device, 'vkDestroyPipeline'));
  vkCreateCommandPool := PFN_vkCreateCommandPool(DeviceProc(Device, 'vkCreateCommandPool'));
  vkDestroyCommandPool := PFN_vkDestroyCommandPool(DeviceProc(Device, 'vkDestroyCommandPool'));
  vkAllocateCommandBuffers := PFN_vkAllocateCommandBuffers(DeviceProc(Device, 'vkAllocateCommandBuffers'));
  vkResetCommandBuffer := PFN_vkResetCommandBuffer(DeviceProc(Device, 'vkResetCommandBuffer'));
  vkBeginCommandBuffer := PFN_vkBeginCommandBuffer(DeviceProc(Device, 'vkBeginCommandBuffer'));
  vkEndCommandBuffer := PFN_vkEndCommandBuffer(DeviceProc(Device, 'vkEndCommandBuffer'));
  vkCmdPipelineBarrier := PFN_vkCmdPipelineBarrier(DeviceProc(Device, 'vkCmdPipelineBarrier'));
  vkCmdBeginRenderPass := PFN_vkCmdBeginRenderPass(DeviceProc(Device, 'vkCmdBeginRenderPass'));
  vkCmdEndRenderPass := PFN_vkCmdEndRenderPass(DeviceProc(Device, 'vkCmdEndRenderPass'));
  vkCmdBindPipeline := PFN_vkCmdBindPipeline(DeviceProc(Device, 'vkCmdBindPipeline'));
  vkCmdPushConstants := PFN_vkCmdPushConstants(DeviceProc(Device, 'vkCmdPushConstants'));
  vkCmdSetViewport := PFN_vkCmdSetViewport(DeviceProc(Device, 'vkCmdSetViewport'));
  vkCmdSetScissor := PFN_vkCmdSetScissor(DeviceProc(Device, 'vkCmdSetScissor'));
  vkCmdDraw := PFN_vkCmdDraw(DeviceProc(Device, 'vkCmdDraw'));
  vkCreateFence := PFN_vkCreateFence(DeviceProc(Device, 'vkCreateFence'));
  vkDestroyFence := PFN_vkDestroyFence(DeviceProc(Device, 'vkDestroyFence'));
  vkResetFences := PFN_vkResetFences(DeviceProc(Device, 'vkResetFences'));
  vkWaitForFences := PFN_vkWaitForFences(DeviceProc(Device, 'vkWaitForFences'));
  vkQueueSubmit := PFN_vkQueueSubmit(DeviceProc(Device, 'vkQueueSubmit'));
  vkDeviceWaitIdle := PFN_vkDeviceWaitIdle(DeviceProc(Device, 'vkDeviceWaitIdle'));
  vkCreateSemaphore := PFN_vkCreateSemaphore(DeviceProc(Device, 'vkCreateSemaphore'));
  vkDestroySemaphore := PFN_vkDestroySemaphore(DeviceProc(Device, 'vkDestroySemaphore'));
  vkCreateBuffer := PFN_vkCreateBuffer(DeviceProc(Device, 'vkCreateBuffer'));
  vkDestroyBuffer := PFN_vkDestroyBuffer(DeviceProc(Device, 'vkDestroyBuffer'));
  vkGetBufferMemoryRequirements := PFN_vkGetBufferMemoryRequirements(DeviceProc(Device, 'vkGetBufferMemoryRequirements'));
  vkBindBufferMemory := PFN_vkBindBufferMemory(DeviceProc(Device, 'vkBindBufferMemory'));
  vkMapMemory := PFN_vkMapMemory(DeviceProc(Device, 'vkMapMemory'));
  vkUnmapMemory := PFN_vkUnmapMemory(DeviceProc(Device, 'vkUnmapMemory'));
  vkFlushMappedMemoryRanges := PFN_vkFlushMappedMemoryRanges(DeviceProc(Device, 'vkFlushMappedMemoryRanges'));
  vkInvalidateMappedMemoryRanges := PFN_vkInvalidateMappedMemoryRanges(DeviceProc(Device, 'vkInvalidateMappedMemoryRanges'));
  vkCreateDescriptorSetLayout := PFN_vkCreateDescriptorSetLayout(DeviceProc(Device, 'vkCreateDescriptorSetLayout'));
  vkDestroyDescriptorSetLayout := PFN_vkDestroyDescriptorSetLayout(DeviceProc(Device, 'vkDestroyDescriptorSetLayout'));
  vkCreateDescriptorPool := PFN_vkCreateDescriptorPool(DeviceProc(Device, 'vkCreateDescriptorPool'));
  vkDestroyDescriptorPool := PFN_vkDestroyDescriptorPool(DeviceProc(Device, 'vkDestroyDescriptorPool'));
  vkResetDescriptorPool := PFN_vkResetDescriptorPool(DeviceProc(Device, 'vkResetDescriptorPool'));
  vkAllocateDescriptorSets := PFN_vkAllocateDescriptorSets(DeviceProc(Device, 'vkAllocateDescriptorSets'));
  vkFreeDescriptorSets := PFN_vkFreeDescriptorSets(DeviceProc(Device, 'vkFreeDescriptorSets'));
  vkUpdateDescriptorSets := PFN_vkUpdateDescriptorSets(DeviceProc(Device, 'vkUpdateDescriptorSets'));
  vkCreateComputePipelines := PFN_vkCreateComputePipelines(DeviceProc(Device, 'vkCreateComputePipelines'));
  vkCmdBindDescriptorSets := PFN_vkCmdBindDescriptorSets(DeviceProc(Device, 'vkCmdBindDescriptorSets'));
  vkCmdDispatch := PFN_vkCmdDispatch(DeviceProc(Device, 'vkCmdDispatch'));
  vkCmdDispatchIndirect := PFN_vkCmdDispatchIndirect(DeviceProc(Device, 'vkCmdDispatchIndirect'));
  vkCmdCopyBuffer := PFN_vkCmdCopyBuffer(DeviceProc(Device, 'vkCmdCopyBuffer'));
  vkCmdFillBuffer := PFN_vkCmdFillBuffer(DeviceProc(Device, 'vkCmdFillBuffer'));
  vkCmdUpdateBuffer := PFN_vkCmdUpdateBuffer(DeviceProc(Device, 'vkCmdUpdateBuffer'));
  vkFreeCommandBuffers := PFN_vkFreeCommandBuffers(DeviceProc(Device, 'vkFreeCommandBuffers'));
  vkResetCommandPool := PFN_vkResetCommandPool(DeviceProc(Device, 'vkResetCommandPool'));
  vkGetFenceStatus := PFN_vkGetFenceStatus(DeviceProc(Device, 'vkGetFenceStatus'));
  vkQueueWaitIdle := PFN_vkQueueWaitIdle(DeviceProc(Device, 'vkQueueWaitIdle'));
  vkCreateQueryPool := PFN_vkCreateQueryPool(DeviceProc(Device, 'vkCreateQueryPool'));
  vkDestroyQueryPool := PFN_vkDestroyQueryPool(DeviceProc(Device, 'vkDestroyQueryPool'));
  vkCmdResetQueryPool := PFN_vkCmdResetQueryPool(DeviceProc(Device, 'vkCmdResetQueryPool'));
  vkCmdWriteTimestamp := PFN_vkCmdWriteTimestamp(DeviceProc(Device, 'vkCmdWriteTimestamp'));
  vkGetQueryPoolResults := PFN_vkGetQueryPoolResults(DeviceProc(Device, 'vkGetQueryPoolResults'));
  vkCreateSampler := PFN_vkCreateSampler(DeviceProc(Device, 'vkCreateSampler'));
  vkDestroySampler := PFN_vkDestroySampler(DeviceProc(Device, 'vkDestroySampler'));
  vkCmdBindVertexBuffers := PFN_vkCmdBindVertexBuffers(DeviceProc(Device, 'vkCmdBindVertexBuffers'));
  vkCmdCopyBufferToImage := PFN_vkCmdCopyBufferToImage(DeviceProc(Device, 'vkCmdCopyBufferToImage'));
  vkCmdCopyImageToBuffer := PFN_vkCmdCopyImageToBuffer(DeviceProc(Device, 'vkCmdCopyImageToBuffer'));
  vkCmdBlitImage := PFN_vkCmdBlitImage(DeviceProc(Device, 'vkCmdBlitImage'));
  vkCmdCopyImage := PFN_vkCmdCopyImage(DeviceProc(Device, 'vkCmdCopyImage'));
  vkCmdSetBlendConstants := PFN_vkCmdSetBlendConstants(DeviceProc(Device, 'vkCmdSetBlendConstants'));
  vkCmdSetStencilReference := PFN_vkCmdSetStencilReference(DeviceProc(Device, 'vkCmdSetStencilReference'));
  vkCmdSetStencilCompareMask := PFN_vkCmdSetStencilCompareMask(DeviceProc(Device, 'vkCmdSetStencilCompareMask'));
  vkCmdSetStencilWriteMask := PFN_vkCmdSetStencilWriteMask(DeviceProc(Device, 'vkCmdSetStencilWriteMask'));
  vkCmdClearAttachments := PFN_vkCmdClearAttachments(DeviceProc(Device, 'vkCmdClearAttachments'));
  vkWaitSemaphores := PFN_vkWaitSemaphores(vkGetDeviceProcAddr(Device, 'vkWaitSemaphores'));
  vkSignalSemaphore := PFN_vkSignalSemaphore(vkGetDeviceProcAddr(Device, 'vkSignalSemaphore'));
  vkGetSemaphoreCounterValue := PFN_vkGetSemaphoreCounterValue(vkGetDeviceProcAddr(Device, 'vkGetSemaphoreCounterValue'));
  if not Assigned(vkWaitSemaphores) then
    vkWaitSemaphores := PFN_vkWaitSemaphores(vkGetDeviceProcAddr(Device, 'vkWaitSemaphoresKHR'));
  if not Assigned(vkSignalSemaphore) then
    vkSignalSemaphore := PFN_vkSignalSemaphore(vkGetDeviceProcAddr(Device, 'vkSignalSemaphoreKHR'));
  if not Assigned(vkGetSemaphoreCounterValue) then
    vkGetSemaphoreCounterValue := PFN_vkGetSemaphoreCounterValue(vkGetDeviceProcAddr(Device, 'vkGetSemaphoreCounterValueKHR'));
end;

end.

