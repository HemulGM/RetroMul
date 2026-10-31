unit RM.Vulkan.Compute;

// Compute work on the GPU for any core, independent of FMX: a device of its
// own (the first with a compute queue, a discrete one preferred), storage
// buffers (in device or host-visible memory, or over memory of the
// emulator's own imported with VK_EXT_external_memory_host, so that a
// shader works on guest RAM in place), kernels from SPIR-V with storage
// buffers and push constants, and command recording that runs them in order
// and waits for them. Buffers' memory is host-coherent where the host sees
// it. One thread at a time.

interface

uses
  System.SysUtils, System.Math, RM.Vulkan.Bindings, RM.Vulkan.Loader;

type
  VkDescriptorSetLayout = UInt64;
  VkDescriptorPool = UInt64;
  VkDescriptorSet = UInt64;

  TVulkanBuffer = class
  private
    FDevice: VkDevice;
    FHandle: VkBuffer;
    FMemory: VkDeviceMemory;
    FSize: UInt64;
    FData: Pointer;
  public
    property Handle: VkBuffer read FHandle;
    property Size: UInt64 read FSize;
    // Host-visible buffers: their memory (coherent), else nil.
    property Data: Pointer read FData;
  end;

  TVulkanKernel = class
  private
    FModule: VkShaderModule;
    FSetLayout: VkDescriptorSetLayout;
    FLayout: VkPipelineLayout;
    FPipeline: VkPipeline;
    FPool: VkDescriptorPool;
    FSet: VkDescriptorSet;
    FBuffers: Integer;
    FPushSize: Integer;
  end;

  TVulkanCompute = class
  private
    FAPI: TVulkanAPI;
    FInstance: VkInstance;
    FPhysical: VkPhysicalDevice;
    FDevice: VkDevice;
    FQueue: VkQueue;
    FFamily: Cardinal;
    FMemory: VkPhysicalDeviceMemoryProperties;
    FPool: VkCommandPool;
    // The command buffer being recorded and its fence: one of two, the other
    // possibly running (Submit).
    FCommands: VkCommandBuffer;
    FFence: VkFence;
    FRecording: Boolean;
    FSlot: Integer;
    FSlotCommands: array[0..1] of VkCommandBuffer;
    FSlotFences: array[0..1] of VkFence;
    FInFlight: array[0..1] of Boolean;
    FName: string;
    FHostImport, FExactFloat, FExactDouble: Boolean;
    FHostAlignment: UInt64;
    FBuffers, FKernels: TArray<TObject>;
    vkGetPhysicalDeviceFeatures: procedure(physicalDevice: VkPhysicalDevice; pFeatures: Pointer);
      {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkCreateBuffer: function(device: VkDevice; pCreateInfo: Pointer; pAllocator: Pointer; pBuffer: Pointer): VkResult;
      {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkDestroyBuffer: procedure(device: VkDevice; buffer: VkBuffer; pAllocator: Pointer);
      {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkGetBufferMemoryRequirements: procedure(device: VkDevice; buffer: VkBuffer; pRequirements: Pointer);
      {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkBindBufferMemory: function(device: VkDevice; buffer: VkBuffer; memory: VkDeviceMemory;
      offset: VkDeviceSize): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkMapMemory: function(device: VkDevice; memory: VkDeviceMemory; offset, size: VkDeviceSize; flags: Cardinal;
      ppData: PPointer): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkCreateDescriptorSetLayout: function(device: VkDevice; pCreateInfo: Pointer; pAllocator: Pointer;
      pSetLayout: Pointer): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkDestroyDescriptorSetLayout: procedure(device: VkDevice; layout: VkDescriptorSetLayout; pAllocator: Pointer);
      {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkCreateDescriptorPool: function(device: VkDevice; pCreateInfo: Pointer; pAllocator: Pointer;
      pPool: Pointer): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkDestroyDescriptorPool: procedure(device: VkDevice; pool: VkDescriptorPool; pAllocator: Pointer);
      {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkAllocateDescriptorSets: function(device: VkDevice; pAllocateInfo: Pointer; pSets: Pointer): VkResult;
      {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkUpdateDescriptorSets: procedure(device: VkDevice; writeCount: Cardinal; pWrites: Pointer; copyCount: Cardinal;
      pCopies: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkCreateComputePipelines: function(device: VkDevice; cache: UInt64; count: Cardinal; pCreateInfos: Pointer;
      pAllocator: Pointer; pPipelines: Pointer): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkCmdBindDescriptorSets: procedure(commandBuffer: VkCommandBuffer; bindPoint: Integer; layout: VkPipelineLayout;
      firstSet, setCount: Cardinal; pSets: Pointer; dynamicOffsetCount: Cardinal; pDynamicOffsets: Pointer);
      {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkCmdDispatch: procedure(commandBuffer: VkCommandBuffer; x, y, z: Cardinal);
      {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkCmdCopyBuffer: procedure(commandBuffer: VkCommandBuffer; src, dst: VkBuffer; regionCount: Cardinal;
      pRegions: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    vkGetMemoryHostPointerPropertiesEXT: function(device: VkDevice; handleType: Cardinal; pHost: Pointer;
      pProperties: Pointer): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    function DeviceProc(const Name: AnsiString; Required: Boolean = True): Pointer;
    function MemoryType(Bits, Wanted: Cardinal; out Index: Cardinal): Boolean;
    procedure SelectDevice;
    procedure CreateDevice;
    procedure Record_;
    procedure SubmitRecorded;
    procedure WaitSlot(Slot: Integer);
    function MakeBuffer(Size: UInt64; Usage: Cardinal; out Requirements: VkMemoryRequirements): VkBuffer;
  public
    constructor Create;
    destructor Destroy; override;
    // A buffer of Size bytes: HostVisible in memory the host maps (Data),
    // else in device-local memory.
    function CreateBuffer(Size: UInt64; HostVisible: Boolean): TVulkanBuffer;
    // A buffer over Size bytes of host memory at Host (aligned to
    // HostAlignment, as its size), or nil where the device cannot import it.
    function ImportHost(Host: Pointer; Size: UInt64): TVulkanBuffer;
    // Frees a buffer no recorded work uses (after Finish) and sets B nil.
    procedure FreeBuffer(var B: TVulkanBuffer);
    // A kernel of SPIR-V (entry point main) with storage buffers at bindings
    // 0..Buffers-1 of set 0 and PushSize bytes of push constants.
    function CreateKernel(const SPIRV: array of Cardinal; Buffers, PushSize: Integer): TVulkanKernel;
    // Kernel's buffers (once, before it is launched).
    procedure Bind(Kernel: TVulkanKernel; const Buffers: array of TVulkanBuffer);
    // Recorded in order, each after the work before it is done with memory.
    procedure Launch(Kernel: TVulkanKernel; const Push; GroupsX, GroupsY, GroupsZ: Cardinal);
    procedure Copy(Src, Dst: TVulkanBuffer; SrcOffset, DstOffset, Size: UInt64);
    // Runs what was recorded and waits for it (and for what Submit started).
    procedure Finish;
    // Starts what was recorded without waiting for it and goes on in the other
    // command buffer (Slot 0 or 1), once what that one ran before is done.
    procedure Submit;
    property Slot: Integer read FSlot;
    property Name: string read FName;
    property HostImport: Boolean read FHostImport;
    // Kernels may keep denormals, signed zeros, infinities and NaNs and round
    // to nearest even (SPV_KHR_float_controls' execution modes): their
    // additions, subtractions and multiplications then round as IEEE 754.
    property ExactFloat: Boolean read FExactFloat;
    // The same for double precision (shaderFloat64 enabled).
    property ExactDouble: Boolean read FExactDouble;
    property HostAlignment: UInt64 read FHostAlignment;
  end;

implementation

const
  VK_QUEUE_COMPUTE_BIT = $00000002;
  VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT = $00000002;
  VK_MEMORY_PROPERTY_HOST_COHERENT_BIT = $00000004;
  VK_BUFFER_USAGE_TRANSFER_SRC_BIT = $00000001;
  VK_BUFFER_USAGE_TRANSFER_DST_BIT = $00000002;
  VK_BUFFER_USAGE_STORAGE_BUFFER_BIT = $00000020;
  VK_DESCRIPTOR_TYPE_STORAGE_BUFFER = 7;
  VK_SHADER_STAGE_COMPUTE_BIT = $00000020;
  VK_PIPELINE_BIND_POINT_COMPUTE = 1;
  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT = $00000800;
  VK_PIPELINE_STAGE_TRANSFER_BIT = $00001000;
  VK_PIPELINE_STAGE_HOST_BIT = $00004000;
  VK_ACCESS_SHADER_READ_BIT = $00000020;
  VK_ACCESS_SHADER_WRITE_BIT = $00000040;
  VK_ACCESS_TRANSFER_READ_BIT = $00000800;
  VK_ACCESS_TRANSFER_WRITE_BIT = $00001000;
  VK_ACCESS_HOST_READ_BIT = $00002000;
  VK_ACCESS_HOST_WRITE_BIT = $00004000;
  VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU = 2;
  VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT = $00000080;
  VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO = 12;
  VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = 32;
  VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO = 33;
  VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO = 34;
  VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET = 35;
  VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO = 29;
  VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO = 39;
  VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO = 40;
  VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO = 42;
  VK_STRUCTURE_TYPE_MEMORY_BARRIER = 46;
  VK_STRUCTURE_TYPE_SUBMIT_INFO = 4;
  VK_STRUCTURE_TYPE_FENCE_CREATE_INFO = 8;
  VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO = 1000072000;
  VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT = 1000178000;
  VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT = 1000178001;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT = 1000178002;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FLOAT_CONTROLS_PROPERTIES = 1000197000;

type
  TBufferCreateInfo = record
    sType: Integer;
    pNext: Pointer;
    flags: Cardinal;
    size: UInt64;
    usage: Cardinal;
    sharingMode: Integer;
    queueFamilyIndexCount: Cardinal;
    pQueueFamilyIndices: PCardinal;
  end;

  TExternalMemoryBufferCreateInfo = record
    sType: Integer;
    pNext: Pointer;
    handleTypes: Cardinal;
  end;

  TImportMemoryHostPointerInfo = record
    sType: Integer;
    pNext: Pointer;
    handleType: Cardinal;
    pHostPointer: Pointer;
  end;

  TMemoryHostPointerProperties = record
    sType: Integer;
    pNext: Pointer;
    memoryTypeBits: Cardinal;
  end;

  TExternalMemoryHostProperties = record
    sType: Integer;
    pNext: Pointer;
    minImportedHostPointerAlignment: UInt64;
  end;

  TFloatControlsProperties = record
    sType: Integer;
    pNext: Pointer;
    denormBehaviorIndependence, roundingModeIndependence: Integer;
    shaderSignedZeroInfNanPreserveFloat16, shaderSignedZeroInfNanPreserveFloat32,
      shaderSignedZeroInfNanPreserveFloat64: Cardinal;
    shaderDenormPreserveFloat16, shaderDenormPreserveFloat32, shaderDenormPreserveFloat64: Cardinal;
    shaderDenormFlushToZeroFloat16, shaderDenormFlushToZeroFloat32, shaderDenormFlushToZeroFloat64: Cardinal;
    shaderRoundingModeRTEFloat16, shaderRoundingModeRTEFloat32, shaderRoundingModeRTEFloat64: Cardinal;
    shaderRoundingModeRTZFloat16, shaderRoundingModeRTZFloat32, shaderRoundingModeRTZFloat64: Cardinal;
  end;

  TDescriptorSetLayoutBinding = record
    binding: Cardinal;
    descriptorType: Integer;
    descriptorCount: Cardinal;
    stageFlags: Cardinal;
    pImmutableSamplers: Pointer;
  end;

  TDescriptorSetLayoutCreateInfo = record
    sType: Integer;
    pNext: Pointer;
    flags: Cardinal;
    bindingCount: Cardinal;
    pBindings: Pointer;
  end;

  TDescriptorPoolSize = record
    type_: Integer;
    descriptorCount: Cardinal;
  end;

  TDescriptorPoolCreateInfo = record
    sType: Integer;
    pNext: Pointer;
    flags: Cardinal;
    maxSets: Cardinal;
    poolSizeCount: Cardinal;
    pPoolSizes: Pointer;
  end;

  TDescriptorSetAllocateInfo = record
    sType: Integer;
    pNext: Pointer;
    descriptorPool: VkDescriptorPool;
    descriptorSetCount: Cardinal;
    pSetLayouts: Pointer;
  end;

  TDescriptorBufferInfo = record
    buffer: VkBuffer;
    offset: UInt64;
    range: UInt64;
  end;

  TWriteDescriptorSet = record
    sType: Integer;
    pNext: Pointer;
    dstSet: VkDescriptorSet;
    dstBinding: Cardinal;
    dstArrayElement: Cardinal;
    descriptorCount: Cardinal;
    descriptorType: Integer;
    pImageInfo: Pointer;
    pBufferInfo: Pointer;
    pTexelBufferView: Pointer;
  end;

  TComputePipelineCreateInfo = record
    sType: Integer;
    pNext: Pointer;
    flags: Cardinal;
    stage: VkPipelineShaderStageCreateInfo;
    layout: VkPipelineLayout;
    basePipelineHandle: VkPipeline;
    basePipelineIndex: Integer;
  end;

  TBufferCopy = record
    srcOffset, dstOffset, size: UInt64;
  end;

{ TVulkanCompute }

constructor TVulkanCompute.Create;
var
  App: VkApplicationInfo;
  Info: VkInstanceCreateInfo;
begin
  inherited Create;
  FAPI := TVulkanAPI.Create;
  App := Default(VkApplicationInfo);
  App.sType := VK_STRUCTURE_TYPE_APPLICATION_INFO;
  App.pApplicationName := 'RetroMul compute';
  App.apiVersion := VK_API_VERSION_1_1;
  Info := Default(VkInstanceCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  Info.pApplicationInfo := @App;
  CheckVulkan(FAPI.vkCreateInstance(@Info, nil, @FInstance), 'vkCreateInstance (Vulkan 1.1)');
  FAPI.LoadInstance(FInstance);
  @vkGetPhysicalDeviceFeatures := Pointer(FAPI.vkGetInstanceProcAddr(FInstance, 'vkGetPhysicalDeviceFeatures'));
  if not Assigned(vkGetPhysicalDeviceFeatures) then
    raise EVulkanError.Create('Missing Vulkan function: vkGetPhysicalDeviceFeatures');
  SelectDevice;
  CreateDevice;
end;

destructor TVulkanCompute.Destroy;
begin
  if FDevice <> nil then
  begin
    FAPI.vkDeviceWaitIdle(FDevice);
    for var O in FKernels do
    begin
      var K := TVulkanKernel(O);
      FAPI.vkDestroyPipeline(FDevice, K.FPipeline, nil);
      FAPI.vkDestroyPipelineLayout(FDevice, K.FLayout, nil);
      vkDestroyDescriptorPool(FDevice, K.FPool, nil);
      vkDestroyDescriptorSetLayout(FDevice, K.FSetLayout, nil);
      FAPI.vkDestroyShaderModule(FDevice, K.FModule, nil);
      K.Free;
    end;
    for var O in FBuffers do
    begin
      var B := TVulkanBuffer(O);
      vkDestroyBuffer(FDevice, B.FHandle, nil);
      FAPI.vkFreeMemory(FDevice, B.FMemory, nil);
      B.Free;
    end;
    for var S := 0 to 1 do
      if FSlotFences[S] <> 0 then
        FAPI.vkDestroyFence(FDevice, FSlotFences[S], nil);
    if FPool <> 0 then
      FAPI.vkDestroyCommandPool(FDevice, FPool, nil);
    FAPI.vkDestroyDevice(FDevice, nil);
  end;
  if FInstance <> nil then
    FAPI.vkDestroyInstance(FInstance, nil);
  FAPI.Free;
  inherited;
end;

function TVulkanCompute.DeviceProc(const Name: AnsiString; Required: Boolean): Pointer;
begin
  Result := Pointer(FAPI.vkGetDeviceProcAddr(FDevice, PAnsiChar(Name)));
  if (Result = nil) and Required then
    raise EVulkanError.Create('Missing Vulkan device function: ' + string(Name));
end;

procedure TVulkanCompute.SelectDevice;
var
  Count: Cardinal;
  Devices: TArray<VkPhysicalDevice>;
  Props: VkPhysicalDeviceProperties2;
begin
  Count := 0;
  CheckVulkan(FAPI.vkEnumeratePhysicalDevices(FInstance, @Count, nil), 'vkEnumeratePhysicalDevices');
  SetLength(Devices, Count);
  if Count > 0 then
    CheckVulkan(FAPI.vkEnumeratePhysicalDevices(FInstance, @Count, @Devices[0]), 'vkEnumeratePhysicalDevices');
  var Best := -1;
  for var K := 0 to High(Devices) do
  begin
    var Families: TArray<VkQueueFamilyProperties>;
    var N: Cardinal := 0;
    FAPI.vkGetPhysicalDeviceQueueFamilyProperties(Devices[K], @N, nil);
    SetLength(Families, N);
    if N > 0 then
      FAPI.vkGetPhysicalDeviceQueueFamilyProperties(Devices[K], @N, @Families[0]);
    var HasCompute := False;
    for var F in Families do
      HasCompute := HasCompute or ((F.queueFlags and VK_QUEUE_COMPUTE_BIT) <> 0);
    if not HasCompute then
      Continue;
    Props := Default(VkPhysicalDeviceProperties2);
    Props.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    FAPI.vkGetPhysicalDeviceProperties2(Devices[K], @Props);
    if Props.properties.apiVersion < VK_API_VERSION_1_1 then
      Continue;
    if (Best < 0) or (Props.properties.deviceType = VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) then
    begin
      Best := K;
      FName := string(UTF8String(PAnsiChar(@Props.properties.deviceName[0])));
      if Props.properties.deviceType = VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU then
        Break;
    end;
  end;
  if Best < 0 then
    raise EVulkanError.Create('No Vulkan 1.1 device with a compute queue.');
  FPhysical := Devices[Best];
  FAPI.vkGetPhysicalDeviceMemoryProperties(FPhysical, @FMemory);
end;

procedure TVulkanCompute.CreateDevice;
const
  HostExtension: PAnsiChar = 'VK_EXT_external_memory_host';
  FloatExtension: PAnsiChar = 'VK_KHR_shader_float_controls';
var
  Families: TArray<VkQueueFamilyProperties>;
  Count: Cardinal;
  Priority: Single;
  QueueInfo: VkDeviceQueueCreateInfo;
  Info: VkDeviceCreateInfo;
  Names: array[0..1] of PAnsiChar;
begin
  Count := 0;
  FAPI.vkGetPhysicalDeviceQueueFamilyProperties(FPhysical, @Count, nil);
  SetLength(Families, Count);
  if Count > 0 then
    FAPI.vkGetPhysicalDeviceQueueFamilyProperties(FPhysical, @Count, @Families[0]);
  FFamily := 0;
  for var K := 0 to High(Families) do
    if (Families[K].queueFlags and VK_QUEUE_COMPUTE_BIT) <> 0 then
    begin
      FFamily := K;
      Break;
    end;
  // The host memory import and the float controls, where there are.
  var Extensions: TArray<VkExtensionProperties>;
  Count := 0;
  FAPI.vkEnumerateDeviceExtensionProperties(FPhysical, nil, @Count, nil);
  SetLength(Extensions, Count);
  if Count > 0 then
    FAPI.vkEnumerateDeviceExtensionProperties(FPhysical, nil, @Count, @Extensions[0]);
  var HasFloat := False;
  for var E in Extensions do
  begin
    FHostImport := FHostImport or (UTF8String(PAnsiChar(@E.extensionName[0])) = UTF8String(HostExtension));
    HasFloat := HasFloat or (UTF8String(PAnsiChar(@E.extensionName[0])) = UTF8String(FloatExtension));
  end;
  if HasFloat then
  begin
    var FloatProps := Default(TFloatControlsProperties);
    FloatProps.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FLOAT_CONTROLS_PROPERTIES;
    var Props := Default(VkPhysicalDeviceProperties2);
    Props.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    Props.pNext := @FloatProps;
    FAPI.vkGetPhysicalDeviceProperties2(FPhysical, @Props);
    FExactFloat := (FloatProps.shaderDenormPreserveFloat32 <> 0) and
      (FloatProps.shaderSignedZeroInfNanPreserveFloat32 <> 0) and (FloatProps.shaderRoundingModeRTEFloat32 <> 0);
    FExactDouble := FExactFloat and (FloatProps.shaderDenormPreserveFloat64 <> 0) and
      (FloatProps.shaderSignedZeroInfNanPreserveFloat64 <> 0) and (FloatProps.shaderRoundingModeRTEFloat64 <> 0);
  end;
  var Supported := Default(VkPhysicalDeviceFeatures);
  vkGetPhysicalDeviceFeatures(FPhysical, @Supported);
  FExactDouble := FExactDouble and (Supported.shaderFloat64 <> 0);
  var Features := Default(VkPhysicalDeviceFeatures);
  Features.shaderFloat64 := Ord(FExactDouble);
  if FHostImport then
  begin
    var HostProps := Default(TExternalMemoryHostProperties);
    HostProps.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT;
    var Props := Default(VkPhysicalDeviceProperties2);
    Props.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    Props.pNext := @HostProps;
    FAPI.vkGetPhysicalDeviceProperties2(FPhysical, @Props);
    FHostAlignment := HostProps.minImportedHostPointerAlignment;
  end;
  Priority := 1;
  QueueInfo := Default(VkDeviceQueueCreateInfo);
  QueueInfo.sType := VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  QueueInfo.queueFamilyIndex := FFamily;
  QueueInfo.queueCount := 1;
  QueueInfo.pQueuePriorities := @Priority;
  Info := Default(VkDeviceCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  Info.queueCreateInfoCount := 1;
  Info.pQueueCreateInfos := @QueueInfo;
  Info.pEnabledFeatures := @Features;
  var NameCount := 0;
  if FHostImport then
  begin
    Names[NameCount] := HostExtension;
    Inc(NameCount);
  end;
  if FExactFloat then
  begin
    Names[NameCount] := FloatExtension;
    Inc(NameCount);
  end;
  if NameCount > 0 then
  begin
    Info.enabledExtensionCount := NameCount;
    Info.ppEnabledExtensionNames := @Names[0];
  end;
  CheckVulkan(FAPI.vkCreateDevice(FPhysical, @Info, nil, @FDevice), 'vkCreateDevice');
  // (Not TVulkanAPI.LoadDevice: it wants the interop extensions' functions.)
  FAPI.vkDestroyDevice := PFN_vkDestroyDevice(DeviceProc('vkDestroyDevice'));
  FAPI.vkGetDeviceQueue := PFN_vkGetDeviceQueue(DeviceProc('vkGetDeviceQueue'));
  FAPI.vkAllocateMemory := PFN_vkAllocateMemory(DeviceProc('vkAllocateMemory'));
  FAPI.vkFreeMemory := PFN_vkFreeMemory(DeviceProc('vkFreeMemory'));
  FAPI.vkCreateShaderModule := PFN_vkCreateShaderModule(DeviceProc('vkCreateShaderModule'));
  FAPI.vkDestroyShaderModule := PFN_vkDestroyShaderModule(DeviceProc('vkDestroyShaderModule'));
  FAPI.vkCreatePipelineLayout := PFN_vkCreatePipelineLayout(DeviceProc('vkCreatePipelineLayout'));
  FAPI.vkDestroyPipelineLayout := PFN_vkDestroyPipelineLayout(DeviceProc('vkDestroyPipelineLayout'));
  FAPI.vkDestroyPipeline := PFN_vkDestroyPipeline(DeviceProc('vkDestroyPipeline'));
  FAPI.vkCreateCommandPool := PFN_vkCreateCommandPool(DeviceProc('vkCreateCommandPool'));
  FAPI.vkDestroyCommandPool := PFN_vkDestroyCommandPool(DeviceProc('vkDestroyCommandPool'));
  FAPI.vkAllocateCommandBuffers := PFN_vkAllocateCommandBuffers(DeviceProc('vkAllocateCommandBuffers'));
  FAPI.vkResetCommandBuffer := PFN_vkResetCommandBuffer(DeviceProc('vkResetCommandBuffer'));
  FAPI.vkBeginCommandBuffer := PFN_vkBeginCommandBuffer(DeviceProc('vkBeginCommandBuffer'));
  FAPI.vkEndCommandBuffer := PFN_vkEndCommandBuffer(DeviceProc('vkEndCommandBuffer'));
  FAPI.vkCmdPipelineBarrier := PFN_vkCmdPipelineBarrier(DeviceProc('vkCmdPipelineBarrier'));
  FAPI.vkCmdBindPipeline := PFN_vkCmdBindPipeline(DeviceProc('vkCmdBindPipeline'));
  FAPI.vkCmdPushConstants := PFN_vkCmdPushConstants(DeviceProc('vkCmdPushConstants'));
  FAPI.vkCreateFence := PFN_vkCreateFence(DeviceProc('vkCreateFence'));
  FAPI.vkDestroyFence := PFN_vkDestroyFence(DeviceProc('vkDestroyFence'));
  FAPI.vkResetFences := PFN_vkResetFences(DeviceProc('vkResetFences'));
  FAPI.vkWaitForFences := PFN_vkWaitForFences(DeviceProc('vkWaitForFences'));
  FAPI.vkQueueSubmit := PFN_vkQueueSubmit(DeviceProc('vkQueueSubmit'));
  FAPI.vkDeviceWaitIdle := PFN_vkDeviceWaitIdle(DeviceProc('vkDeviceWaitIdle'));
  FAPI.vkGetDeviceQueue(FDevice, FFamily, 0, @FQueue);
  @vkCreateBuffer := DeviceProc('vkCreateBuffer');
  @vkDestroyBuffer := DeviceProc('vkDestroyBuffer');
  @vkGetBufferMemoryRequirements := DeviceProc('vkGetBufferMemoryRequirements');
  @vkBindBufferMemory := DeviceProc('vkBindBufferMemory');
  @vkMapMemory := DeviceProc('vkMapMemory');
  @vkCreateDescriptorSetLayout := DeviceProc('vkCreateDescriptorSetLayout');
  @vkDestroyDescriptorSetLayout := DeviceProc('vkDestroyDescriptorSetLayout');
  @vkCreateDescriptorPool := DeviceProc('vkCreateDescriptorPool');
  @vkDestroyDescriptorPool := DeviceProc('vkDestroyDescriptorPool');
  @vkAllocateDescriptorSets := DeviceProc('vkAllocateDescriptorSets');
  @vkUpdateDescriptorSets := DeviceProc('vkUpdateDescriptorSets');
  @vkCreateComputePipelines := DeviceProc('vkCreateComputePipelines');
  @vkCmdBindDescriptorSets := DeviceProc('vkCmdBindDescriptorSets');
  @vkCmdDispatch := DeviceProc('vkCmdDispatch');
  @vkCmdCopyBuffer := DeviceProc('vkCmdCopyBuffer');
  if FHostImport then
    @vkGetMemoryHostPointerPropertiesEXT := DeviceProc('vkGetMemoryHostPointerPropertiesEXT', False);
  FHostImport := FHostImport and Assigned(vkGetMemoryHostPointerPropertiesEXT);
  var PoolInfo := Default(VkCommandPoolCreateInfo);
  PoolInfo.sType := VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
  PoolInfo.flags := VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
  PoolInfo.queueFamilyIndex := FFamily;
  CheckVulkan(FAPI.vkCreateCommandPool(FDevice, @PoolInfo, nil, @FPool), 'vkCreateCommandPool');
  var Alloc := Default(VkCommandBufferAllocateInfo);
  Alloc.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
  Alloc.commandPool := FPool;
  Alloc.level := VK_COMMAND_BUFFER_LEVEL_PRIMARY;
  Alloc.commandBufferCount := 2;
  CheckVulkan(FAPI.vkAllocateCommandBuffers(FDevice, @Alloc, @FSlotCommands[0]), 'vkAllocateCommandBuffers');
  var FenceInfo := Default(VkFenceCreateInfo);
  FenceInfo.sType := VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
  for var S := 0 to 1 do
    CheckVulkan(FAPI.vkCreateFence(FDevice, @FenceInfo, nil, @FSlotFences[S]), 'vkCreateFence');
  FSlot := 0;
  FCommands := FSlotCommands[0];
  FFence := FSlotFences[0];
end;

function TVulkanCompute.MemoryType(Bits, Wanted: Cardinal; out Index: Cardinal): Boolean;
begin
  for var K := 0 to Integer(FMemory.memoryTypeCount) - 1 do
    if ((Bits and (Cardinal(1) shl K)) <> 0) and ((FMemory.memoryTypes[K].propertyFlags and Wanted) = Wanted) then
    begin
      Index := K;
      Exit(True);
    end;
  Result := False;
end;

function TVulkanCompute.MakeBuffer(Size: UInt64; Usage: Cardinal; out Requirements: VkMemoryRequirements): VkBuffer;
begin
  var Info := Default(TBufferCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  Info.size := Size;
  Info.usage := Usage;
  Info.sharingMode := VK_SHARING_MODE_EXCLUSIVE;
  CheckVulkan(vkCreateBuffer(FDevice, @Info, nil, @Result), 'vkCreateBuffer');
  vkGetBufferMemoryRequirements(FDevice, Result, @Requirements);
end;

function TVulkanCompute.CreateBuffer(Size: UInt64; HostVisible: Boolean): TVulkanBuffer;
var
  Req: VkMemoryRequirements;
  TypeIndex: Cardinal;
begin
  Result := TVulkanBuffer.Create;
  FBuffers := FBuffers + [Result];
  Result.FDevice := FDevice;
  Result.FSize := Size;
  Result.FHandle := MakeBuffer(Size, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT or VK_BUFFER_USAGE_TRANSFER_SRC_BIT or
    VK_BUFFER_USAGE_TRANSFER_DST_BIT, Req);
  var Wanted: Cardinal := VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
  if HostVisible then
    Wanted := VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
  if not MemoryType(Req.memoryTypeBits, Wanted, TypeIndex) then
    raise EVulkanError.Create('No Vulkan memory type for a buffer.');
  var Alloc := Default(VkMemoryAllocateInfo);
  Alloc.sType := VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  Alloc.allocationSize := Req.size;
  Alloc.memoryTypeIndex := TypeIndex;
  CheckVulkan(FAPI.vkAllocateMemory(FDevice, @Alloc, nil, @Result.FMemory), 'vkAllocateMemory');
  CheckVulkan(vkBindBufferMemory(FDevice, Result.FHandle, Result.FMemory, 0), 'vkBindBufferMemory');
  if HostVisible then
    CheckVulkan(vkMapMemory(FDevice, Result.FMemory, 0, Size, 0, @Result.FData), 'vkMapMemory');
end;

function TVulkanCompute.ImportHost(Host: Pointer; Size: UInt64): TVulkanBuffer;
var
  Req: VkMemoryRequirements;
  TypeIndex: Cardinal;
begin
  Result := nil;
  if not FHostImport or (FHostAlignment = 0) or ((NativeUInt(Host) mod FHostAlignment) <> 0) or
    ((Size mod FHostAlignment) <> 0) then
    Exit;
  var Pointer_ := Default(TMemoryHostPointerProperties);
  Pointer_.sType := VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT;
  if vkGetMemoryHostPointerPropertiesEXT(FDevice, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, Host,
    @Pointer_) <> VK_SUCCESS then
    Exit;
  var External := Default(TExternalMemoryBufferCreateInfo);
  External.sType := VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO;
  External.handleTypes := VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
  var Info := Default(TBufferCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  Info.pNext := @External;
  Info.size := Size;
  Info.usage := VK_BUFFER_USAGE_STORAGE_BUFFER_BIT or VK_BUFFER_USAGE_TRANSFER_SRC_BIT or
    VK_BUFFER_USAGE_TRANSFER_DST_BIT;
  Info.sharingMode := VK_SHARING_MODE_EXCLUSIVE;
  var Handle: VkBuffer;
  CheckVulkan(vkCreateBuffer(FDevice, @Info, nil, @Handle), 'vkCreateBuffer (host)');
  vkGetBufferMemoryRequirements(FDevice, Handle, @Req);
  if (Req.size > Size) or not MemoryType(Req.memoryTypeBits and Pointer_.memoryTypeBits,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, TypeIndex) then
  begin
    vkDestroyBuffer(FDevice, Handle, nil);
    Exit;
  end;
  var Import := Default(TImportMemoryHostPointerInfo);
  Import.sType := VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT;
  Import.handleType := VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
  Import.pHostPointer := Host;
  var Alloc := Default(VkMemoryAllocateInfo);
  Alloc.sType := VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  Alloc.pNext := @Import;
  Alloc.allocationSize := Size;
  Alloc.memoryTypeIndex := TypeIndex;
  var Memory: VkDeviceMemory;
  if FAPI.vkAllocateMemory(FDevice, @Alloc, nil, @Memory) <> VK_SUCCESS then
  begin
    vkDestroyBuffer(FDevice, Handle, nil);
    Exit;
  end;
  if vkBindBufferMemory(FDevice, Handle, Memory, 0) <> VK_SUCCESS then
  begin
    vkDestroyBuffer(FDevice, Handle, nil);
    FAPI.vkFreeMemory(FDevice, Memory, nil);
    Exit;
  end;
  Result := TVulkanBuffer.Create;
  Result.FDevice := FDevice;
  Result.FHandle := Handle;
  Result.FMemory := Memory;
  Result.FSize := Size;
  Result.FData := Host;
  FBuffers := FBuffers + [Result];
end;

procedure TVulkanCompute.FreeBuffer(var B: TVulkanBuffer);
begin
  if B = nil then
    Exit;
  for var K := 0 to High(FBuffers) do
    if FBuffers[K] = B then
    begin
      Delete(FBuffers, K, 1);
      Break;
    end;
  vkDestroyBuffer(FDevice, B.FHandle, nil);
  FAPI.vkFreeMemory(FDevice, B.FMemory, nil);
  FreeAndNil(B);
end;

function TVulkanCompute.CreateKernel(const SPIRV: array of Cardinal; Buffers, PushSize: Integer): TVulkanKernel;
var
  Bindings: TArray<TDescriptorSetLayoutBinding>;
begin
  Result := TVulkanKernel.Create;
  Result.FBuffers := Buffers;
  Result.FPushSize := PushSize;
  var ModuleInfo := Default(VkShaderModuleCreateInfo);
  ModuleInfo.sType := VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
  ModuleInfo.codeSize := Length(SPIRV) * 4;
  ModuleInfo.pCode := @SPIRV[0];
  CheckVulkan(FAPI.vkCreateShaderModule(FDevice, @ModuleInfo, nil, @Result.FModule), 'vkCreateShaderModule');
  SetLength(Bindings, Buffers);
  for var K := 0 to Buffers - 1 do
  begin
    Bindings[K] := Default(TDescriptorSetLayoutBinding);
    Bindings[K].binding := K;
    Bindings[K].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    Bindings[K].descriptorCount := 1;
    Bindings[K].stageFlags := VK_SHADER_STAGE_COMPUTE_BIT;
  end;
  var SetInfo := Default(TDescriptorSetLayoutCreateInfo);
  SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  SetInfo.bindingCount := Buffers;
  if Buffers > 0 then
    SetInfo.pBindings := @Bindings[0];
  CheckVulkan(vkCreateDescriptorSetLayout(FDevice, @SetInfo, nil, @Result.FSetLayout),
    'vkCreateDescriptorSetLayout');
  var Range := Default(VkPushConstantRange);
  Range.stageFlags := VK_SHADER_STAGE_COMPUTE_BIT;
  Range.size := PushSize;
  var LayoutInfo := Default(VkPipelineLayoutCreateInfo);
  LayoutInfo.sType := VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  LayoutInfo.setLayoutCount := 1;
  LayoutInfo.pSetLayouts := @Result.FSetLayout;
  if PushSize > 0 then
  begin
    LayoutInfo.pushConstantRangeCount := 1;
    LayoutInfo.pPushConstantRanges := @Range;
  end;
  CheckVulkan(FAPI.vkCreatePipelineLayout(FDevice, @LayoutInfo, nil, @Result.FLayout), 'vkCreatePipelineLayout');
  var Pipeline := Default(TComputePipelineCreateInfo);
  Pipeline.sType := VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
  Pipeline.stage.sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Pipeline.stage.stage := VK_SHADER_STAGE_COMPUTE_BIT;
  Pipeline.stage.module := Result.FModule;
  Pipeline.stage.pName := 'main';
  Pipeline.layout := Result.FLayout;
  Pipeline.basePipelineIndex := -1;
  CheckVulkan(vkCreateComputePipelines(FDevice, 0, 1, @Pipeline, nil, @Result.FPipeline),
    'vkCreateComputePipelines');
  var PoolSize := Default(TDescriptorPoolSize);
  PoolSize.type_ := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
  PoolSize.descriptorCount := Max(1, Buffers);
  var PoolInfo := Default(TDescriptorPoolCreateInfo);
  PoolInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
  PoolInfo.maxSets := 1;
  PoolInfo.poolSizeCount := 1;
  PoolInfo.pPoolSizes := @PoolSize;
  CheckVulkan(vkCreateDescriptorPool(FDevice, @PoolInfo, nil, @Result.FPool), 'vkCreateDescriptorPool');
  var SetAlloc := Default(TDescriptorSetAllocateInfo);
  SetAlloc.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  SetAlloc.descriptorPool := Result.FPool;
  SetAlloc.descriptorSetCount := 1;
  SetAlloc.pSetLayouts := @Result.FSetLayout;
  CheckVulkan(vkAllocateDescriptorSets(FDevice, @SetAlloc, @Result.FSet), 'vkAllocateDescriptorSets');
  FKernels := FKernels + [Result];
end;

procedure TVulkanCompute.Bind(Kernel: TVulkanKernel; const Buffers: array of TVulkanBuffer);
var
  Infos: TArray<TDescriptorBufferInfo>;
  Writes: TArray<TWriteDescriptorSet>;
begin
  SetLength(Infos, Length(Buffers));
  SetLength(Writes, Length(Buffers));
  for var K := 0 to High(Buffers) do
  begin
    Infos[K].buffer := Buffers[K].FHandle;
    Infos[K].offset := 0;
    Infos[K].range := Buffers[K].FSize;
    Writes[K] := Default(TWriteDescriptorSet);
    Writes[K].sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    Writes[K].dstSet := Kernel.FSet;
    Writes[K].dstBinding := K;
    Writes[K].descriptorCount := 1;
    Writes[K].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    Writes[K].pBufferInfo := @Infos[K];
  end;
  if Length(Writes) > 0 then
    vkUpdateDescriptorSets(FDevice, Length(Writes), @Writes[0], 0, nil);
end;

procedure TVulkanCompute.Record_;
begin
  // A barrier between commands: each sees the memory the ones before wrote
  // (and the host's writes before the first).
  if not FRecording then
  begin
    var Begin_ := Default(VkCommandBufferBeginInfo);
    Begin_.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    Begin_.flags := VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    CheckVulkan(FAPI.vkBeginCommandBuffer(FCommands, @Begin_), 'vkBeginCommandBuffer');
    FRecording := True;
  end;
  var Barrier := Default(VkMemoryBarrier);
  Barrier.sType := VK_STRUCTURE_TYPE_MEMORY_BARRIER;
  Barrier.srcAccessMask := VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_WRITE_BIT or VK_ACCESS_HOST_WRITE_BIT;
  Barrier.dstAccessMask := VK_ACCESS_SHADER_READ_BIT or VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_READ_BIT or
    VK_ACCESS_TRANSFER_WRITE_BIT;
  FAPI.vkCmdPipelineBarrier(FCommands, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT or
    VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1,
    @Barrier, 0, nil, 0, nil);
end;

procedure TVulkanCompute.Launch(Kernel: TVulkanKernel; const Push; GroupsX, GroupsY, GroupsZ: Cardinal);
begin
  Record_;
  FAPI.vkCmdBindPipeline(FCommands, VK_PIPELINE_BIND_POINT_COMPUTE, Kernel.FPipeline);
  vkCmdBindDescriptorSets(FCommands, VK_PIPELINE_BIND_POINT_COMPUTE, Kernel.FLayout, 0, 1, @Kernel.FSet, 0, nil);
  if Kernel.FPushSize > 0 then
    FAPI.vkCmdPushConstants(FCommands, Kernel.FLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, Kernel.FPushSize, @Push);
  vkCmdDispatch(FCommands, GroupsX, GroupsY, GroupsZ);
end;

procedure TVulkanCompute.Copy(Src, Dst: TVulkanBuffer; SrcOffset, DstOffset, Size: UInt64);
begin
  Record_;
  var Region: TBufferCopy;
  Region.srcOffset := SrcOffset;
  Region.dstOffset := DstOffset;
  Region.size := Size;
  vkCmdCopyBuffer(FCommands, Src.FHandle, Dst.FHandle, 1, @Region);
end;

procedure TVulkanCompute.SubmitRecorded;
begin
  // The host sees what the commands wrote.
  var Barrier := Default(VkMemoryBarrier);
  Barrier.sType := VK_STRUCTURE_TYPE_MEMORY_BARRIER;
  Barrier.srcAccessMask := VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_WRITE_BIT;
  Barrier.dstAccessMask := VK_ACCESS_HOST_READ_BIT;
  FAPI.vkCmdPipelineBarrier(FCommands, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT,
    VK_PIPELINE_STAGE_HOST_BIT, 0, 1, @Barrier, 0, nil, 0, nil);
  CheckVulkan(FAPI.vkEndCommandBuffer(FCommands), 'vkEndCommandBuffer');
  FRecording := False;
  var Submit := Default(VkSubmitInfo);
  Submit.sType := VK_STRUCTURE_TYPE_SUBMIT_INFO;
  Submit.commandBufferCount := 1;
  Submit.pCommandBuffers := @FCommands;
  CheckVulkan(FAPI.vkQueueSubmit(FQueue, 1, @Submit, FFence), 'vkQueueSubmit');
  FInFlight[FSlot] := True;
end;

procedure TVulkanCompute.WaitSlot(Slot: Integer);
begin
  if not FInFlight[Slot] then
    Exit;
  CheckVulkan(FAPI.vkWaitForFences(FDevice, 1, @FSlotFences[Slot], 1, UInt64(-1)), 'vkWaitForFences');
  CheckVulkan(FAPI.vkResetFences(FDevice, 1, @FSlotFences[Slot]), 'vkResetFences');
  CheckVulkan(FAPI.vkResetCommandBuffer(FSlotCommands[Slot], 0), 'vkResetCommandBuffer');
  FInFlight[Slot] := False;
end;

procedure TVulkanCompute.Finish;
begin
  if FRecording then
    SubmitRecorded;
  // Submission order: the other buffer's work was submitted first.
  WaitSlot(1 - FSlot);
  WaitSlot(FSlot);
end;

procedure TVulkanCompute.Submit;
begin
  if FRecording then
    SubmitRecorded;
  FSlot := 1 - FSlot;
  FCommands := FSlotCommands[FSlot];
  FFence := FSlotFences[FSlot];
  WaitSlot(FSlot);
end;

end.
