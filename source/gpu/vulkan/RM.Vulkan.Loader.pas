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
  {$IF Defined(LINUX) or Defined(ANDROID)}
  vkGetPhysicalDeviceExternalSemaphoreProperties := PFN_vkGetPhysicalDeviceExternalSemaphoreProperties(
    InstanceProc(Instance, 'vkGetPhysicalDeviceExternalSemaphoreProperties'));
  {$ENDIF}
end;

procedure TVulkanAPI.LoadDevice(Device: VkDevice);
begin
  vkDestroyDevice := PFN_vkDestroyDevice(DeviceProc(Device, 'vkDestroyDevice'));
  vkGetDeviceQueue := PFN_vkGetDeviceQueue(DeviceProc(Device, 'vkGetDeviceQueue'));
  vkCreateImage := PFN_vkCreateImage(DeviceProc(Device, 'vkCreateImage'));
  vkDestroyImage := PFN_vkDestroyImage(DeviceProc(Device, 'vkDestroyImage'));
  vkGetImageMemoryRequirements := PFN_vkGetImageMemoryRequirements(DeviceProc(Device, 'vkGetImageMemoryRequirements'));
  {$IFDEF MSWINDOWS}
  vkGetMemoryWin32HandlePropertiesKHR := PFN_vkGetMemoryWin32HandlePropertiesKHR(DeviceProc(Device, 'vkGetMemoryWin32HandlePropertiesKHR'));
  {$ELSEIF Defined(LINUX) or Defined(ANDROID)}
  vkCreateSemaphore := PFN_vkCreateSemaphore(DeviceProc(Device, 'vkCreateSemaphore'));
  vkDestroySemaphore := PFN_vkDestroySemaphore(DeviceProc(Device, 'vkDestroySemaphore'));
  vkGetSemaphoreFdKHR := PFN_vkGetSemaphoreFdKHR(DeviceProc(Device, 'vkGetSemaphoreFdKHR'));
  {$IFDEF ANDROID}
  vkImportSemaphoreFdKHR := PFN_vkImportSemaphoreFdKHR(DeviceProc(Device, 'vkImportSemaphoreFdKHR'));
  vkGetAndroidHardwareBufferPropertiesANDROID := PFN_vkGetAndroidHardwareBufferPropertiesANDROID(
    DeviceProc(Device, 'vkGetAndroidHardwareBufferPropertiesANDROID'));
  {$ELSE}
  vkGetMemoryFdKHR := PFN_vkGetMemoryFdKHR(DeviceProc(Device, 'vkGetMemoryFdKHR'));
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
end;

end.

