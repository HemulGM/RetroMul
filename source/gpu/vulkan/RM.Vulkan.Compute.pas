unit RM.Vulkan.Compute;

// A headless Vulkan compute context: its own instance and device (no window,
// no FMX), one compute queue, buffers in device-local or host-visible memory,
// compute kernels from SPIR-V words and command buffers with a fence.
// Vulkan 1.2 is required (timeline semaphores, float controls, 8/16-bit
// storage are core there); what the device supports is in Features.
interface

uses
  System.SysUtils, System.Diagnostics, RM.Vulkan.Bindings, RM.Vulkan.Loader;

type
  TVulkanComputeFeatures = record
    Int64, Int16, Int8, Float64: Boolean;
    Storage8, Storage16: Boolean;
    Timeline: Boolean;
    // Float controls: denormals kept, round to nearest even, signed zero/inf/NaN kept.
    DenormPreserve32, DenormPreserve64: Boolean;
    RoundEven32, RoundEven64: Boolean;
    SignedZeroInfNan32, SignedZeroInfNan64: Boolean;
    // With a graphics queue: fixed-function features enabled when supported.
    DepthClamp, LogicOp, DualSrcBlend: Boolean;
    // With a graphics queue: fragment shaders that write storage images in
    // primitive order (VK_EXT_fragment_shader_interlock, pixel interlock).
    PixelInterlock: Boolean;
  end;

  // Device: device-local, not mapped. Upload: host-visible for CPU writes.
  // Readback: host-visible and cached for CPU reads. Shared: device-local and
  // host-visible when the device has such memory (resizable BAR), else host memory.
  TVulkanBufferKind = (vbkDevice, vbkUpload, vbkReadback, vbkShared);

  TVulkanCompute = class;

  TVulkanBuffer = class
  private
    FOwner: TVulkanCompute;
    FHandle: VkBuffer;
    FMemory: VkDeviceMemory;
    FSize, FAllocated: UInt64;
    FKind: TVulkanBufferKind;
    FData: PByte;
    FCoherent, FDeviceLocal: Boolean;
    procedure Range(Offset, Size: UInt64; out R: VkMappedMemoryRange);
  public
    constructor Create(Owner: TVulkanCompute; Size: UInt64; Kind: TVulkanBufferKind; Usage: Cardinal);
    destructor Destroy; override;
    // Host writes -> device and device writes -> host for non-coherent memory.
    procedure Flush(Offset: UInt64 = 0; Size: UInt64 = VK_WHOLE_SIZE);
    procedure Invalidate(Offset: UInt64 = 0; Size: UInt64 = VK_WHOLE_SIZE);
    procedure Write(Offset: UInt64; const Source; Count: NativeUInt);
    procedure Read(Offset: UInt64; var Dest; Count: NativeUInt);
    property Handle: VkBuffer read FHandle;
    property Size: UInt64 read FSize;
    property Kind: TVulkanBufferKind read FKind;
    property Data: PByte read FData;
    property Coherent: Boolean read FCoherent;
    property DeviceLocal: Boolean read FDeviceLocal;
  end;

  // A compute pipeline whose set 0 holds storage buffers at bindings
  // 0..Buffers-1, with an optional push constant block and uint32
  // specialization constants (constant_id = index). It has Sets descriptor
  // sets (for buffers in flight at the same time); dispatches use ActiveSet.
  TVulkanKernel = class
  private
    FOwner: TVulkanCompute;
    FSetLayout: VkDescriptorSetLayout;
    FLayout: VkPipelineLayout;
    FPipeline: VkPipeline;
    FPool: VkDescriptorPool;
    FSets: TArray<VkDescriptorSet>;
    FActive: Integer;
    FBuffers: Integer;
    FPushSize: Cardinal;
  public
    constructor Create(Owner: TVulkanCompute; const Code: array of Cardinal; Buffers: Integer; PushSize: Cardinal;
      const Spec: array of Cardinal; Sets: Integer = 1);
    destructor Destroy; override;
    // Not while a command buffer using the set is pending.
    procedure Bind(Binding: Integer; Buffer: TVulkanBuffer; Offset: UInt64 = 0; Size: UInt64 = VK_WHOLE_SIZE); overload;
    procedure Bind(SetIndex, Binding: Integer; Buffer: TVulkanBuffer; Offset: UInt64 = 0;
      Size: UInt64 = VK_WHOLE_SIZE); overload;
    property Pipeline: VkPipeline read FPipeline;
    property Layout: VkPipelineLayout read FLayout;
    property PushSize: Cardinal read FPushSize;
    property ActiveSet: Integer read FActive write FActive;
  end;

  TVulkanCommands = class
  private
    FOwner: TVulkanCompute;
    FHandle: VkCommandBuffer;
    FFence: VkFence;
    FQueries: VkQueryPool;
    FQueryCount: Cardinal;
    FRecording, FPending: Boolean;
    FBound: TVulkanKernel;
    FBoundSet: Integer;
    FSpin: Int64;
  public
    constructor Create(Owner: TVulkanCompute; Timestamps: Cardinal = 0);
    destructor Destroy; override;
    procedure Start;
    procedure Dispatch(Kernel: TVulkanKernel; X, Y, Z: Cardinal); reintroduce; overload;
    procedure Dispatch(Kernel: TVulkanKernel; X, Y, Z: Cardinal; const Push; Size: Cardinal); reintroduce; overload;
    procedure DispatchIndirect(Kernel: TVulkanKernel; Args: TVulkanBuffer; Offset: UInt64; const Push; Size: Cardinal);
    procedure Copy(Source, Dest: TVulkanBuffer; SourceOffset, DestOffset, Size: UInt64);
    procedure Fill(Buffer: TVulkanBuffer; Offset, Size: UInt64; Value: Cardinal);
    // At most 65536 bytes, a multiple of 4.
    procedure Update(Buffer: TVulkanBuffer; Offset: UInt64; const Data; Size: Cardinal);
    procedure Barrier(SourceStage, SourceAccess, DestStage, DestAccess: Cardinal);
    // Shader and transfer writes are visible to later shaders, transfers and the host.
    procedure FullBarrier;
    procedure Timestamp(Index: Cardinal);
    procedure Submit; overload;
    // Also signals Timeline to Value when it completes.
    procedure Submit(Timeline: VkSemaphore; Value: UInt64); overload;
    procedure Wait;
    function Done: Boolean;
    procedure Run;
    // Nanoseconds between two timestamps of the last completed submission.
    function Elapsed(First, Last: Cardinal): Double;
    property Handle: VkCommandBuffer read FHandle;
    property Recording: Boolean read FRecording;
    property Pending: Boolean read FPending;
    // Wait polls the fence this long before it blocks.
    property SpinMicroseconds: Int64 read FSpin write FSpin;
  end;

  TVulkanCompute = class
  private
    FAPI: TVulkanAPI;
    FInstance: VkInstance;
    FPhysicalDevice: VkPhysicalDevice;
    FDevice: VkDevice;
    FQueue: VkQueue;
    FQueueFamily: Cardinal;
    FProperties: VkPhysicalDeviceProperties;
    FMemory: VkPhysicalDeviceMemoryProperties;
    FFeatures: TVulkanComputeFeatures;
    FPool: VkCommandPool;
    FName: string;
    FValidation: Boolean;
    FGraphics: Boolean;
    procedure CreateInstance(Validation: Boolean);
    procedure SelectDevice(const DeviceName: string);
    procedure CreateDevice;
    function HasExtension(const Name: AnsiString): Boolean;
  public
    // Graphics: the queue also renders (a family with graphics and compute).
    constructor Create(const DeviceName: string = ''; Validation: Boolean = False; Graphics: Boolean = False);
    destructor Destroy; override;
    // A memory type index with all Required flags, trying each preference in order; -1 if none.
    function FindMemory(TypeBits, Required: Cardinal; const Preferred: array of Cardinal): Integer;
    function CreateBuffer(Size: UInt64;
      Kind: TVulkanBufferKind;
      Usage: Cardinal = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT or VK_BUFFER_USAGE_TRANSFER_SRC_BIT or
        VK_BUFFER_USAGE_TRANSFER_DST_BIT): TVulkanBuffer;
    function CreateShaderModule(const Code: array of Cardinal): VkShaderModule;
    function CreateKernel(const Code: array of Cardinal; Buffers: Integer;
      PushSize: Cardinal = 0): TVulkanKernel; overload;
    function CreateKernel(const Code: array of Cardinal; Buffers: Integer; PushSize: Cardinal;
      const Spec: array of Cardinal; Sets: Integer = 1): TVulkanKernel; overload;
    function CreateCommands(Timestamps: Cardinal = 0): TVulkanCommands;
    function CreateTimeline(Initial: UInt64 = 0): VkSemaphore;
    procedure DestroyTimeline(Semaphore: VkSemaphore);
    function TimelineValue(Semaphore: VkSemaphore): UInt64;
    procedure WaitTimeline(Semaphore: VkSemaphore; Value: UInt64);
    procedure WaitIdle;
    property API: TVulkanAPI read FAPI;
    property Instance: VkInstance read FInstance;
    property PhysicalDevice: VkPhysicalDevice read FPhysicalDevice;
    property Device: VkDevice read FDevice;
    property Queue: VkQueue read FQueue;
    property QueueFamily: Cardinal read FQueueFamily;
    property Properties: VkPhysicalDeviceProperties read FProperties;
    property Features: TVulkanComputeFeatures read FFeatures;
    property CommandPool: VkCommandPool read FPool;
    property Name: string read FName;
    // The Khronos validation layer is active (it reports to stdout).
    property Validation: Boolean read FValidation;
    property Graphics: Boolean read FGraphics;
  end;

// A compute context, or nil (with the reason) when there is no usable Vulkan device.
function TryCreateVulkanCompute(out Compute: TVulkanCompute; out Error: string; const DeviceName: string = '';
  Validation: Boolean = False; Graphics: Boolean = False): Boolean;

implementation

function TryCreateVulkanCompute(out Compute: TVulkanCompute; out Error: string; const DeviceName: string;
  Validation, Graphics: Boolean): Boolean;
begin
  Compute := nil;
  Error := '';
  try
    Compute := TVulkanCompute.Create(DeviceName, Validation, Graphics);
  except
    on E: Exception do
      Error := E.Message;
  end;
  Result := Compute <> nil;
end;

{ TVulkanCompute }

constructor TVulkanCompute.Create(const DeviceName: string; Validation, Graphics: Boolean);
begin
  inherited Create;
  FGraphics := Graphics;
  FAPI := TVulkanAPI.Create;
  CreateInstance(Validation);
  SelectDevice(DeviceName);
  CreateDevice;
end;

destructor TVulkanCompute.Destroy;
begin
  if FAPI <> nil then
  begin
    if (FDevice <> nil) and Assigned(FAPI.vkDestroyDevice) then
    begin
      if Assigned(FAPI.vkDeviceWaitIdle) then
        FAPI.vkDeviceWaitIdle(FDevice);
      if FPool <> 0 then
        FAPI.vkDestroyCommandPool(FDevice, FPool, nil);
      FAPI.vkDestroyDevice(FDevice, nil);
    end;
    if (FInstance <> nil) and Assigned(FAPI.vkDestroyInstance) then
      FAPI.vkDestroyInstance(FInstance, nil);
  end;
  FAPI.Free;
  inherited;
end;

procedure TVulkanCompute.CreateInstance(Validation: Boolean);
const
  ValidationLayer: PAnsiChar = 'VK_LAYER_KHRONOS_validation';
var
  ApplicationInfo: VkApplicationInfo;
  InstanceInfo: VkInstanceCreateInfo;
  Version: Cardinal;
  Layers: array[0..0] of PAnsiChar;
begin
  Version := VK_API_VERSION_1_1;
  if Assigned(FAPI.vkEnumerateInstanceVersion) then
    FAPI.vkEnumerateInstanceVersion(@Version);
  if Version < VK_API_VERSION_1_2 then
    raise EVulkanError.Create('The Vulkan loader does not support Vulkan 1.2.');
  ApplicationInfo := Default(VkApplicationInfo);
  ApplicationInfo.sType := VK_STRUCTURE_TYPE_APPLICATION_INFO;
  ApplicationInfo.pApplicationName := 'RetroMul compute';
  ApplicationInfo.pEngineName := 'RetroMul';
  ApplicationInfo.apiVersion := VK_API_VERSION_1_2;
  InstanceInfo := Default(VkInstanceCreateInfo);
  InstanceInfo.sType := VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  InstanceInfo.pApplicationInfo := @ApplicationInfo;
  if Validation then
  begin
    Layers[0] := ValidationLayer;
    InstanceInfo.enabledLayerCount := 1;
    InstanceInfo.ppEnabledLayerNames := @Layers[0];
    if FAPI.vkCreateInstance(@InstanceInfo, nil, @FInstance) = VK_SUCCESS then
    begin
      FAPI.LoadInstance(FInstance);
      FValidation := True;
      Exit;
    end;
    InstanceInfo.enabledLayerCount := 0;
    InstanceInfo.ppEnabledLayerNames := nil;
  end;
  CheckVulkan(FAPI.vkCreateInstance(@InstanceInfo, nil, @FInstance), 'vkCreateInstance (Vulkan 1.2)');
  FAPI.LoadInstance(FInstance);
end;

function ComputeFamily(API: TVulkanAPI; Device: VkPhysicalDevice; Graphics: Boolean): Integer;
var
  Count: Cardinal;
  Families: TArray<VkQueueFamilyProperties>;
begin
  Count := 0;
  API.vkGetPhysicalDeviceQueueFamilyProperties(Device, @Count, nil);
  SetLength(Families, Count);
  if Count <> 0 then
    API.vkGetPhysicalDeviceQueueFamilyProperties(Device, @Count, @Families[0]);
  var Want: Cardinal := VK_QUEUE_COMPUTE_BIT;
  if Graphics then
    Want := Want or VK_QUEUE_GRAPHICS_BIT;
  for var I := 0 to High(Families) do
    if (Families[I].queueFlags and Want = Want) and (Families[I].queueCount > 0) then
      Exit(I);
  Result := -1;
end;

procedure TVulkanCompute.SelectDevice(const DeviceName: string);
const
  Rank: array[0..4] of Integer = (1, 3, 4, 2, 0); // other, integrated, discrete, virtual, CPU
var
  Count: Cardinal;
  Devices: TArray<VkPhysicalDevice>;
  P: VkPhysicalDeviceProperties;
begin
  Count := 0;
  CheckVulkan(FAPI.vkEnumeratePhysicalDevices(FInstance, @Count, nil), 'vkEnumeratePhysicalDevices');
  SetLength(Devices, Count);
  if Count <> 0 then
    CheckVulkan(FAPI.vkEnumeratePhysicalDevices(FInstance, @Count, @Devices[0]), 'vkEnumeratePhysicalDevices');
  var Best := -1;
  for var Device in Devices do
  begin
    FAPI.vkGetPhysicalDeviceProperties(Device, @P);
    if P.apiVersion < VK_API_VERSION_1_2 then
      Continue;
    var DeviceText := string(UTF8String(PAnsiChar(@P.deviceName[0])));
    if (DeviceName <> '') and (Pos(DeviceName.ToLower, DeviceText.ToLower) = 0) then
      Continue;
    if ComputeFamily(FAPI, Device, FGraphics) < 0 then
      Continue;
    var Score := 0;
    if (P.deviceType >= 0) and (P.deviceType <= High(Rank)) then
      Score := Rank[P.deviceType];
    if Score > Best then
    begin
      Best := Score;
      FPhysicalDevice := Device;
      FProperties := P;
      FName := DeviceText;
    end;
  end;
  if FPhysicalDevice = nil then
    if DeviceName <> '' then
      raise EVulkanError.Create('No Vulkan 1.2 compute device matches "' + DeviceName + '".')
    else if FGraphics then
      raise EVulkanError.Create('No Vulkan 1.2 device with a graphics and compute queue.')
    else
      raise EVulkanError.Create('No Vulkan 1.2 device with a compute queue.');
  FQueueFamily := ComputeFamily(FAPI, FPhysicalDevice, FGraphics);
  FAPI.vkGetPhysicalDeviceMemoryProperties(FPhysicalDevice, @FMemory);
end;

function TVulkanCompute.HasExtension(const Name: AnsiString): Boolean;
var
  Count: Cardinal;
  List: TArray<VkExtensionProperties>;
begin
  Count := 0;
  if FAPI.vkEnumerateDeviceExtensionProperties(FPhysicalDevice, nil, @Count, nil) <> VK_SUCCESS then
    Exit(False);
  SetLength(List, Count);
  if (Count > 0) and (FAPI.vkEnumerateDeviceExtensionProperties(FPhysicalDevice, nil, @Count, @List[0]) <>
    VK_SUCCESS) then
    Exit(False);
  for var I := 0 to Integer(Count) - 1 do
    if AnsiString(PAnsiChar(@List[I].extensionName[0])) = Name then
      Exit(True);
  Result := False;
end;

procedure TVulkanCompute.CreateDevice;
var
  Features: VkPhysicalDeviceFeatures2;
  Storage16: VkPhysicalDevice16BitStorageFeatures;
  Storage8: VkPhysicalDevice8BitStorageFeatures;
  Int8: VkPhysicalDeviceShaderFloat16Int8Features;
  Timeline: VkPhysicalDeviceTimelineSemaphoreFeatures;
  Interlock: VkPhysicalDeviceFragmentShaderInterlockFeaturesEXT;
  Controls: VkPhysicalDeviceFloatControlsProperties;
  Properties: VkPhysicalDeviceProperties2;
  Priority: Single;
  QueueInfo: VkDeviceQueueCreateInfo;
  DeviceInfo: VkDeviceCreateInfo;
  PoolInfo: VkCommandPoolCreateInfo;
begin
  Storage16 := Default(VkPhysicalDevice16BitStorageFeatures);
  Storage16.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES;
  Storage8 := Default(VkPhysicalDevice8BitStorageFeatures);
  Storage8.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_8BIT_STORAGE_FEATURES;
  Storage8.pNext := @Storage16;
  Int8 := Default(VkPhysicalDeviceShaderFloat16Int8Features);
  Int8.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_FLOAT16_INT8_FEATURES;
  Int8.pNext := @Storage8;
  Timeline := Default(VkPhysicalDeviceTimelineSemaphoreFeatures);
  Timeline.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES;
  Timeline.pNext := @Int8;
  Features := Default(VkPhysicalDeviceFeatures2);
  Features.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
  Features.pNext := @Timeline;
  Interlock := Default(VkPhysicalDeviceFragmentShaderInterlockFeaturesEXT);
  Interlock.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT;
  var HasInterlock := FGraphics and HasExtension(VK_EXT_FRAGMENT_SHADER_INTERLOCK_EXTENSION_NAME);
  if HasInterlock then
  begin
    Interlock.pNext := Features.pNext;
    Features.pNext := @Interlock;
  end;
  FAPI.vkGetPhysicalDeviceFeatures2(FPhysicalDevice, @Features);
  Controls := Default(VkPhysicalDeviceFloatControlsProperties);
  Controls.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FLOAT_CONTROLS_PROPERTIES;
  Properties := Default(VkPhysicalDeviceProperties2);
  Properties.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
  Properties.pNext := @Controls;
  FAPI.vkGetPhysicalDeviceProperties2(FPhysicalDevice, @Properties);

  FFeatures.Int64 := Features.features.shaderInt64 <> 0;
  FFeatures.Int16 := Features.features.shaderInt16 <> 0;
  FFeatures.Float64 := Features.features.shaderFloat64 <> 0;
  FFeatures.Int8 := Int8.shaderInt8 <> 0;
  FFeatures.Storage8 := (Storage8.storageBuffer8BitAccess <> 0) and (Storage8.uniformAndStorageBuffer8BitAccess <> 0);
  FFeatures.Storage16 := (Storage16.storageBuffer16BitAccess <> 0) and
    (Storage16.uniformAndStorageBuffer16BitAccess <> 0);
  FFeatures.Timeline := Timeline.timelineSemaphore <> 0;
  FFeatures.DenormPreserve32 := Controls.shaderDenormPreserveFloat32 <> 0;
  FFeatures.DenormPreserve64 := Controls.shaderDenormPreserveFloat64 <> 0;
  FFeatures.RoundEven32 := Controls.shaderRoundingModeRTEFloat32 <> 0;
  FFeatures.RoundEven64 := Controls.shaderRoundingModeRTEFloat64 <> 0;
  FFeatures.SignedZeroInfNan32 := Controls.shaderSignedZeroInfNanPreserveFloat32 <> 0;
  FFeatures.SignedZeroInfNan64 := Controls.shaderSignedZeroInfNanPreserveFloat64 <> 0;

  // Enable exactly the supported subset of what the kernels use.
  var Core := Default(VkPhysicalDeviceFeatures);
  Core.shaderInt64 := Features.features.shaderInt64;
  Core.shaderInt16 := Features.features.shaderInt16;
  Core.shaderFloat64 := Features.features.shaderFloat64;
  if FGraphics then
  begin
    Core.depthClamp := Features.features.depthClamp;
    Core.logicOp := Features.features.logicOp;
    Core.dualSrcBlend := Features.features.dualSrcBlend;
    FFeatures.DepthClamp := Core.depthClamp <> 0;
    FFeatures.LogicOp := Core.logicOp <> 0;
    FFeatures.DualSrcBlend := Core.dualSrcBlend <> 0;
    if HasInterlock and (Interlock.fragmentShaderPixelInterlock <> 0) and
      (Features.features.fragmentStoresAndAtomics <> 0) then
    begin
      Core.fragmentStoresAndAtomics := 1;
      Interlock.fragmentShaderSampleInterlock := 0;
      Interlock.fragmentShaderShadingRateInterlock := 0;
      FFeatures.PixelInterlock := True;
    end;
  end;
  // The interlock features go to the device only with their extension.
  if HasInterlock and not FFeatures.PixelInterlock then
    Features.pNext := Interlock.pNext;
  Features.features := Core;
  Storage16.storagePushConstant16 := 0;
  Storage16.storageInputOutput16 := 0;
  Storage8.storagePushConstant8 := 0;
  Int8.shaderFloat16 := 0;
  if not FFeatures.Timeline then
    Timeline.timelineSemaphore := 0;

  Priority := 1;
  QueueInfo := Default(VkDeviceQueueCreateInfo);
  QueueInfo.sType := VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  QueueInfo.queueFamilyIndex := FQueueFamily;
  QueueInfo.queueCount := 1;
  QueueInfo.pQueuePriorities := @Priority;
  DeviceInfo := Default(VkDeviceCreateInfo);
  DeviceInfo.sType := VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  DeviceInfo.pNext := @Features;
  DeviceInfo.queueCreateInfoCount := 1;
  DeviceInfo.pQueueCreateInfos := @QueueInfo;
  var Extensions: array[0..0] of PAnsiChar;
  if FFeatures.PixelInterlock then
  begin
    Extensions[0] := VK_EXT_FRAGMENT_SHADER_INTERLOCK_EXTENSION_NAME;
    DeviceInfo.enabledExtensionCount := 1;
    DeviceInfo.ppEnabledExtensionNames := @Extensions[0];
  end;
  CheckVulkan(FAPI.vkCreateDevice(FPhysicalDevice, @DeviceInfo, nil, @FDevice), 'vkCreateDevice');
  FAPI.LoadDevice(FDevice);
  FAPI.vkGetDeviceQueue(FDevice, FQueueFamily, 0, @FQueue);
  FFeatures.Timeline := FFeatures.Timeline and Assigned(FAPI.vkWaitSemaphores) and
    Assigned(FAPI.vkGetSemaphoreCounterValue);

  PoolInfo := Default(VkCommandPoolCreateInfo);
  PoolInfo.sType := VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
  PoolInfo.flags := VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
  PoolInfo.queueFamilyIndex := FQueueFamily;
  CheckVulkan(FAPI.vkCreateCommandPool(FDevice, @PoolInfo, nil, @FPool), 'vkCreateCommandPool');
end;

function TVulkanCompute.FindMemory(TypeBits, Required: Cardinal; const Preferred: array of Cardinal): Integer;
begin
  for var Want in Preferred do
    for var I := 0 to Integer(FMemory.memoryTypeCount) - 1 do
      if (TypeBits and (Cardinal(1) shl I) <> 0) and (FMemory.memoryTypes[I].propertyFlags and (Required or Want) =
        Required or Want) then
        Exit(I);
  for var I := 0 to Integer(FMemory.memoryTypeCount) - 1 do
    if (TypeBits and (Cardinal(1) shl I) <> 0) and (FMemory.memoryTypes[I].propertyFlags and Required = Required) then
      Exit(I);
  Result := -1;
end;

function TVulkanCompute.CreateBuffer(Size: UInt64; Kind: TVulkanBufferKind; Usage: Cardinal): TVulkanBuffer;
begin
  Result := TVulkanBuffer.Create(Self, Size, Kind, Usage);
end;

function TVulkanCompute.CreateShaderModule(const Code: array of Cardinal): VkShaderModule;
var
  Info: VkShaderModuleCreateInfo;
begin
  if Length(Code) = 0 then
    raise EVulkanError.Create('Empty SPIR-V module.');
  Info := Default(VkShaderModuleCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
  Info.codeSize := Length(Code) * SizeOf(Cardinal);
  Info.pCode := @Code[0];
  CheckVulkan(FAPI.vkCreateShaderModule(FDevice, @Info, nil, @Result), 'vkCreateShaderModule');
end;

function TVulkanCompute.CreateKernel(const Code: array of Cardinal; Buffers: Integer;
  PushSize: Cardinal): TVulkanKernel;
begin
  Result := TVulkanKernel.Create(Self, Code, Buffers, PushSize, []);
end;

function TVulkanCompute.CreateKernel(const Code: array of Cardinal; Buffers: Integer; PushSize: Cardinal;
  const Spec: array of Cardinal; Sets: Integer): TVulkanKernel;
begin
  Result := TVulkanKernel.Create(Self, Code, Buffers, PushSize, Spec, Sets);
end;

function TVulkanCompute.CreateCommands(Timestamps: Cardinal): TVulkanCommands;
begin
  Result := TVulkanCommands.Create(Self, Timestamps);
end;

function TVulkanCompute.CreateTimeline(Initial: UInt64): VkSemaphore;
var
  TypeInfo: VkSemaphoreTypeCreateInfo;
  Info: VkSemaphoreCreateInfo;
begin
  if not FFeatures.Timeline then
    raise EVulkanError.Create('The Vulkan device has no timeline semaphores.');
  TypeInfo := Default(VkSemaphoreTypeCreateInfo);
  TypeInfo.sType := VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
  TypeInfo.semaphoreType := VK_SEMAPHORE_TYPE_TIMELINE;
  TypeInfo.initialValue := Initial;
  Info := Default(VkSemaphoreCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
  Info.pNext := @TypeInfo;
  CheckVulkan(FAPI.vkCreateSemaphore(FDevice, @Info, nil, @Result), 'vkCreateSemaphore (timeline)');
end;

procedure TVulkanCompute.DestroyTimeline(Semaphore: VkSemaphore);
begin
  if Semaphore <> 0 then
    FAPI.vkDestroySemaphore(FDevice, Semaphore, nil);
end;

function TVulkanCompute.TimelineValue(Semaphore: VkSemaphore): UInt64;
begin
  CheckVulkan(FAPI.vkGetSemaphoreCounterValue(FDevice, Semaphore, @Result), 'vkGetSemaphoreCounterValue');
end;

procedure TVulkanCompute.WaitTimeline(Semaphore: VkSemaphore; Value: UInt64);
var
  Info: VkSemaphoreWaitInfo;
begin
  Info := Default(VkSemaphoreWaitInfo);
  Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
  Info.semaphoreCount := 1;
  Info.pSemaphores := @Semaphore;
  Info.pValues := @Value;
  CheckVulkan(FAPI.vkWaitSemaphores(FDevice, @Info, UInt64($FFFFFFFFFFFFFFFF)), 'vkWaitSemaphores');
end;

procedure TVulkanCompute.WaitIdle;
begin
  CheckVulkan(FAPI.vkDeviceWaitIdle(FDevice), 'vkDeviceWaitIdle');
end;

{ TVulkanBuffer }

constructor TVulkanBuffer.Create(Owner: TVulkanCompute; Size: UInt64; Kind: TVulkanBufferKind; Usage: Cardinal);
const
  Visible = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
  Coherent = VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
  Cached = VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
  Local = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
var
  Info: VkBufferCreateInfo;
  Requirements: VkMemoryRequirements;
  Allocate: VkMemoryAllocateInfo;
begin
  inherited Create;
  FOwner := Owner;
  FSize := Size;
  FKind := Kind;
  var API := Owner.API;
  Info := Default(VkBufferCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  Info.size := Size;
  Info.usage := Usage;
  Info.sharingMode := VK_SHARING_MODE_EXCLUSIVE;
  CheckVulkan(API.vkCreateBuffer(Owner.Device, @Info, nil, @FHandle), 'vkCreateBuffer');
  API.vkGetBufferMemoryRequirements(Owner.Device, FHandle, @Requirements);
  var MemoryType: Integer;
  case Kind of
    vbkDevice:
      MemoryType := Owner.FindMemory(Requirements.memoryTypeBits, Local, []);
    vbkUpload:
      MemoryType := Owner.FindMemory(Requirements.memoryTypeBits, Visible, [Coherent]);
    vbkReadback:
      MemoryType := Owner.FindMemory(Requirements.memoryTypeBits, Visible, [Cached or Coherent, Cached, Coherent]);
  else
    MemoryType := Owner.FindMemory(Requirements.memoryTypeBits, Visible, [Local or Coherent, Local, Coherent]);
  end;
  if (MemoryType < 0) and (Kind = vbkDevice) then
    MemoryType := Owner.FindMemory(Requirements.memoryTypeBits, 0, []);
  if MemoryType < 0 then
    raise EVulkanError.Create('No Vulkan memory type for a buffer.');
  var Flags := Owner.FMemory.memoryTypes[MemoryType].propertyFlags;
  FCoherent := Flags and Coherent <> 0;
  FDeviceLocal := Flags and Local <> 0;
  FAllocated := Requirements.size;
  Allocate := Default(VkMemoryAllocateInfo);
  Allocate.sType := VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  Allocate.allocationSize := Requirements.size;
  Allocate.memoryTypeIndex := MemoryType;
  CheckVulkan(API.vkAllocateMemory(Owner.Device, @Allocate, nil, @FMemory), 'vkAllocateMemory (buffer)');
  CheckVulkan(API.vkBindBufferMemory(Owner.Device, FHandle, FMemory, 0), 'vkBindBufferMemory');
  if (Kind <> vbkDevice) and (Flags and Visible <> 0) then
    CheckVulkan(API.vkMapMemory(Owner.Device, FMemory, 0, VK_WHOLE_SIZE, 0, @FData), 'vkMapMemory');
end;

destructor TVulkanBuffer.Destroy;
begin
  if FOwner <> nil then
  begin
    var API := FOwner.API;
    if FData <> nil then
      API.vkUnmapMemory(FOwner.Device, FMemory);
    if FHandle <> 0 then
      API.vkDestroyBuffer(FOwner.Device, FHandle, nil);
    if FMemory <> 0 then
      API.vkFreeMemory(FOwner.Device, FMemory, nil);
  end;
  inherited;
end;

procedure TVulkanBuffer.Range(Offset, Size: UInt64; out R: VkMappedMemoryRange);
begin
  var Atom := FOwner.Properties.limits.nonCoherentAtomSize;
  if Atom = 0 then
    Atom := 1;
  if Size = VK_WHOLE_SIZE then
    Size := FSize - Offset;
  var First := Offset - Offset mod Atom;
  var Last := Offset + Size;
  Last := ((Last + Atom - 1) div Atom) * Atom;
  if Last > FAllocated then
    Last := FAllocated;
  R := Default(VkMappedMemoryRange);
  R.sType := VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
  R.memory := FMemory;
  R.offset := First;
  if Last >= FAllocated then
    R.size := VK_WHOLE_SIZE
  else
    R.size := Last - First;
end;

procedure TVulkanBuffer.Flush(Offset, Size: UInt64);
var
  R: VkMappedMemoryRange;
begin
  if (FData = nil) or FCoherent then
    Exit;
  Range(Offset, Size, R);
  CheckVulkan(FOwner.API.vkFlushMappedMemoryRanges(FOwner.Device, 1, @R), 'vkFlushMappedMemoryRanges');
end;

procedure TVulkanBuffer.Invalidate(Offset, Size: UInt64);
var
  R: VkMappedMemoryRange;
begin
  if (FData = nil) or FCoherent then
    Exit;
  Range(Offset, Size, R);
  CheckVulkan(FOwner.API.vkInvalidateMappedMemoryRanges(FOwner.Device, 1, @R), 'vkInvalidateMappedMemoryRanges');
end;

procedure TVulkanBuffer.Write(Offset: UInt64; const Source; Count: NativeUInt);
begin
  if FData = nil then
    raise EVulkanError.Create('The buffer is not host-visible.');
  if Offset + Count > FSize then
    raise ERangeError.Create('Vulkan buffer write out of range.');
  Move(Source, FData[Offset], Count);
  Flush(Offset, Count);
end;

procedure TVulkanBuffer.Read(Offset: UInt64; var Dest; Count: NativeUInt);
begin
  if FData = nil then
    raise EVulkanError.Create('The buffer is not host-visible.');
  if Offset + Count > FSize then
    raise ERangeError.Create('Vulkan buffer read out of range.');
  Invalidate(Offset, Count);
  Move(FData[Offset], Dest, Count);
end;

{ TVulkanKernel }

constructor TVulkanKernel.Create(Owner: TVulkanCompute; const Code: array of Cardinal; Buffers: Integer;
  PushSize: Cardinal; const Spec: array of Cardinal; Sets: Integer);
var
  Layouts: TArray<VkDescriptorSetLayout>;
  Bindings: TArray<VkDescriptorSetLayoutBinding>;
  SetInfo: VkDescriptorSetLayoutCreateInfo;
  Push: VkPushConstantRange;
  LayoutInfo: VkPipelineLayoutCreateInfo;
  Entries: TArray<VkSpecializationMapEntry>;
  SpecInfo: VkSpecializationInfo;
  PipelineInfo: VkComputePipelineCreateInfo;
  PoolSize: VkDescriptorPoolSize;
  PoolInfo: VkDescriptorPoolCreateInfo;
  Allocate: VkDescriptorSetAllocateInfo;
begin
  inherited Create;
  FOwner := Owner;
  FBuffers := Buffers;
  FPushSize := PushSize;
  var API := Owner.API;
  var Device := Owner.Device;
  SetLength(Bindings, Buffers);
  for var I := 0 to Buffers - 1 do
  begin
    Bindings[I] := Default(VkDescriptorSetLayoutBinding);
    Bindings[I].binding := I;
    Bindings[I].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    Bindings[I].descriptorCount := 1;
    Bindings[I].stageFlags := VK_SHADER_STAGE_COMPUTE_BIT;
  end;
  SetInfo := Default(VkDescriptorSetLayoutCreateInfo);
  SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  SetInfo.bindingCount := Buffers;
  if Buffers > 0 then
    SetInfo.pBindings := @Bindings[0];
  CheckVulkan(API.vkCreateDescriptorSetLayout(Device, @SetInfo, nil, @FSetLayout), 'vkCreateDescriptorSetLayout');
  LayoutInfo := Default(VkPipelineLayoutCreateInfo);
  LayoutInfo.sType := VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  LayoutInfo.setLayoutCount := 1;
  LayoutInfo.pSetLayouts := @FSetLayout;
  if PushSize > 0 then
  begin
    Push.stageFlags := VK_SHADER_STAGE_COMPUTE_BIT;
    Push.offset := 0;
    Push.size := PushSize;
    LayoutInfo.pushConstantRangeCount := 1;
    LayoutInfo.pPushConstantRanges := @Push;
  end;
  CheckVulkan(API.vkCreatePipelineLayout(Device, @LayoutInfo, nil, @FLayout), 'vkCreatePipelineLayout');

  var Module := Owner.CreateShaderModule(Code);
  try
    PipelineInfo := Default(VkComputePipelineCreateInfo);
    PipelineInfo.sType := VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    PipelineInfo.stage.sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    PipelineInfo.stage.stage := VK_SHADER_STAGE_COMPUTE_BIT;
    PipelineInfo.stage.module := Module;
    PipelineInfo.stage.pName := 'main';
    if Length(Spec) > 0 then
    begin
      SetLength(Entries, Length(Spec));
      for var I := 0 to High(Spec) do
      begin
        Entries[I].constantID := I;
        Entries[I].offset := I * SizeOf(Cardinal);
        Entries[I].size := SizeOf(Cardinal);
      end;
      SpecInfo.mapEntryCount := Length(Spec);
      SpecInfo.pMapEntries := @Entries[0];
      SpecInfo.dataSize := Length(Spec) * SizeOf(Cardinal);
      SpecInfo.pData := @Spec[0];
      PipelineInfo.stage.pSpecializationInfo := @SpecInfo;
    end;
    PipelineInfo.layout := FLayout;
    PipelineInfo.basePipelineIndex := -1;
    CheckVulkan(API.vkCreateComputePipelines(Device, 0, 1, @PipelineInfo, nil, @FPipeline), 'vkCreateComputePipelines');
  finally
    API.vkDestroyShaderModule(Device, Module, nil);
  end;

  if Sets < 1 then
    Sets := 1;
  SetLength(FSets, Sets);
  if Buffers > 0 then
  begin
    PoolSize.&type := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    PoolSize.descriptorCount := Buffers * Sets;
    PoolInfo := Default(VkDescriptorPoolCreateInfo);
    PoolInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    PoolInfo.maxSets := Sets;
    PoolInfo.poolSizeCount := 1;
    PoolInfo.pPoolSizes := @PoolSize;
    CheckVulkan(API.vkCreateDescriptorPool(Device, @PoolInfo, nil, @FPool), 'vkCreateDescriptorPool');
    SetLength(Layouts, Sets);
    for var I := 0 to Sets - 1 do
      Layouts[I] := FSetLayout;
    Allocate := Default(VkDescriptorSetAllocateInfo);
    Allocate.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    Allocate.descriptorPool := FPool;
    Allocate.descriptorSetCount := Sets;
    Allocate.pSetLayouts := @Layouts[0];
    CheckVulkan(API.vkAllocateDescriptorSets(Device, @Allocate, @FSets[0]), 'vkAllocateDescriptorSets');
  end;
end;

destructor TVulkanKernel.Destroy;
begin
  if FOwner <> nil then
  begin
    var API := FOwner.API;
    var Device := FOwner.Device;
    if FPool <> 0 then
      API.vkDestroyDescriptorPool(Device, FPool, nil);
    if FPipeline <> 0 then
      API.vkDestroyPipeline(Device, FPipeline, nil);
    if FLayout <> 0 then
      API.vkDestroyPipelineLayout(Device, FLayout, nil);
    if FSetLayout <> 0 then
      API.vkDestroyDescriptorSetLayout(Device, FSetLayout, nil);
  end;
  inherited;
end;

procedure TVulkanKernel.Bind(Binding: Integer; Buffer: TVulkanBuffer; Offset, Size: UInt64);
begin
  Bind(0, Binding, Buffer, Offset, Size);
end;

procedure TVulkanKernel.Bind(SetIndex, Binding: Integer; Buffer: TVulkanBuffer; Offset, Size: UInt64);
var
  Info: VkDescriptorBufferInfo;
  Write: VkWriteDescriptorSet;
begin
  if (Binding < 0) or (Binding >= FBuffers) or (SetIndex < 0) or (SetIndex > High(FSets)) then
    raise ERangeError.CreateFmt('Kernel binding %d of set %d out of range.', [Binding, SetIndex]);
  Info.buffer := Buffer.Handle;
  Info.offset := Offset;
  Info.range := Size;
  Write := Default(VkWriteDescriptorSet);
  Write.sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
  Write.dstSet := FSets[SetIndex];
  Write.dstBinding := Binding;
  Write.descriptorCount := 1;
  Write.descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
  Write.pBufferInfo := @Info;
  FOwner.API.vkUpdateDescriptorSets(FOwner.Device, 1, @Write, 0, nil);
end;

{ TVulkanCommands }

constructor TVulkanCommands.Create(Owner: TVulkanCompute; Timestamps: Cardinal);
var
  Allocate: VkCommandBufferAllocateInfo;
  FenceInfo: VkFenceCreateInfo;
  QueryInfo: VkQueryPoolCreateInfo;
begin
  inherited Create;
  FOwner := Owner;
  var API := Owner.API;
  Allocate := Default(VkCommandBufferAllocateInfo);
  Allocate.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
  Allocate.commandPool := Owner.CommandPool;
  Allocate.level := VK_COMMAND_BUFFER_LEVEL_PRIMARY;
  Allocate.commandBufferCount := 1;
  CheckVulkan(API.vkAllocateCommandBuffers(Owner.Device, @Allocate, @FHandle), 'vkAllocateCommandBuffers');
  FenceInfo := Default(VkFenceCreateInfo);
  FenceInfo.sType := VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
  CheckVulkan(API.vkCreateFence(Owner.Device, @FenceInfo, nil, @FFence), 'vkCreateFence');
  if Timestamps > 0 then
  begin
    QueryInfo := Default(VkQueryPoolCreateInfo);
    QueryInfo.sType := VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO;
    QueryInfo.queryType := VK_QUERY_TYPE_TIMESTAMP;
    QueryInfo.queryCount := Timestamps;
    CheckVulkan(API.vkCreateQueryPool(Owner.Device, @QueryInfo, nil, @FQueries), 'vkCreateQueryPool');
    FQueryCount := Timestamps;
  end;
end;

destructor TVulkanCommands.Destroy;
begin
  if FOwner <> nil then
  begin
    var API := FOwner.API;
    if FPending then
      API.vkWaitForFences(FOwner.Device, 1, @FFence, 1, UInt64($FFFFFFFFFFFFFFFF));
    if FQueries <> 0 then
      API.vkDestroyQueryPool(FOwner.Device, FQueries, nil);
    if FFence <> 0 then
      API.vkDestroyFence(FOwner.Device, FFence, nil);
    if FHandle <> nil then
      API.vkFreeCommandBuffers(FOwner.Device, FOwner.CommandPool, 1, @FHandle);
  end;
  inherited;
end;

procedure TVulkanCommands.Start;
var
  Info: VkCommandBufferBeginInfo;
begin
  if FPending then
    Wait;
  Info := Default(VkCommandBufferBeginInfo);
  Info.sType := VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
  Info.flags := VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  CheckVulkan(FOwner.API.vkBeginCommandBuffer(FHandle, @Info), 'vkBeginCommandBuffer');
  FRecording := True;
  FBound := nil;
  if FQueryCount > 0 then
    FOwner.API.vkCmdResetQueryPool(FHandle, FQueries, 0, FQueryCount);
end;

procedure TVulkanCommands.Dispatch(Kernel: TVulkanKernel; X, Y, Z: Cardinal);
begin
  Dispatch(Kernel, X, Y, Z, PByte(nil)^, 0);
end;

procedure TVulkanCommands.Dispatch(Kernel: TVulkanKernel; X, Y, Z: Cardinal; const Push; Size: Cardinal);
begin
  var API := FOwner.API;
  if FBound <> Kernel then
  begin
    API.vkCmdBindPipeline(FHandle, VK_PIPELINE_BIND_POINT_COMPUTE, Kernel.FPipeline);
    FBoundSet := -1;
    FBound := Kernel;
  end;
  if (FBoundSet <> Kernel.FActive) and (Kernel.FSets[Kernel.FActive] <> 0) then
  begin
    API.vkCmdBindDescriptorSets(FHandle, VK_PIPELINE_BIND_POINT_COMPUTE, Kernel.FLayout, 0, 1,
      @Kernel.FSets[Kernel.FActive], 0, nil);
    FBoundSet := Kernel.FActive;
  end;
  if Size > 0 then
    API.vkCmdPushConstants(FHandle, Kernel.FLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, Size, @Push);
  if (X > 0) and (Y > 0) and (Z > 0) then
    API.vkCmdDispatch(FHandle, X, Y, Z);
end;

procedure TVulkanCommands.DispatchIndirect(Kernel: TVulkanKernel; Args: TVulkanBuffer; Offset: UInt64; const Push;
  Size: Cardinal);
begin
  Dispatch(Kernel, 0, 0, 0, Push, Size);
  FOwner.API.vkCmdDispatchIndirect(FHandle, Args.Handle, Offset);
end;

procedure TVulkanCommands.Copy(Source, Dest: TVulkanBuffer; SourceOffset, DestOffset, Size: UInt64);
var
  Region: VkBufferCopy;
begin
  if Size = 0 then
    Exit;
  Region.srcOffset := SourceOffset;
  Region.dstOffset := DestOffset;
  Region.size := Size;
  FOwner.API.vkCmdCopyBuffer(FHandle, Source.Handle, Dest.Handle, 1, @Region);
end;

procedure TVulkanCommands.Fill(Buffer: TVulkanBuffer; Offset, Size: UInt64; Value: Cardinal);
begin
  FOwner.API.vkCmdFillBuffer(FHandle, Buffer.Handle, Offset, Size, Value);
end;

procedure TVulkanCommands.Update(Buffer: TVulkanBuffer; Offset: UInt64; const Data; Size: Cardinal);
begin
  FOwner.API.vkCmdUpdateBuffer(FHandle, Buffer.Handle, Offset, Size, @Data);
end;

procedure TVulkanCommands.Barrier(SourceStage, SourceAccess, DestStage, DestAccess: Cardinal);
var
  B: VkMemoryBarrier;
begin
  B := Default(VkMemoryBarrier);
  B.sType := VK_STRUCTURE_TYPE_MEMORY_BARRIER;
  B.srcAccessMask := SourceAccess;
  B.dstAccessMask := DestAccess;
  FOwner.API.vkCmdPipelineBarrier(FHandle, SourceStage, DestStage, 0, 1, @B, 0, nil, 0, nil);
end;

procedure TVulkanCommands.FullBarrier;
begin
  Barrier(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_SHADER_WRITE_BIT or
    VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT or
    VK_PIPELINE_STAGE_HOST_BIT or VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
    VK_ACCESS_SHADER_READ_BIT or VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_READ_BIT or
    VK_ACCESS_TRANSFER_WRITE_BIT or VK_ACCESS_HOST_READ_BIT or VK_ACCESS_INDIRECT_COMMAND_READ_BIT);
end;

procedure TVulkanCommands.Timestamp(Index: Cardinal);
begin
  if Index < FQueryCount then
    FOwner.API.vkCmdWriteTimestamp(FHandle, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, FQueries, Index);
end;

procedure TVulkanCommands.Submit;
begin
  Submit(0, 0);
end;

procedure TVulkanCommands.Submit(Timeline: VkSemaphore; Value: UInt64);
var
  Info: VkSubmitInfo;
  TimelineInfo: VkTimelineSemaphoreSubmitInfo;
begin
  if not FRecording then
    raise EVulkanError.Create('Submit without Start.');
  CheckVulkan(FOwner.API.vkEndCommandBuffer(FHandle), 'vkEndCommandBuffer');
  FRecording := False;
  Info := Default(VkSubmitInfo);
  Info.sType := VK_STRUCTURE_TYPE_SUBMIT_INFO;
  Info.commandBufferCount := 1;
  Info.pCommandBuffers := @FHandle;
  if Timeline <> 0 then
  begin
    TimelineInfo := Default(VkTimelineSemaphoreSubmitInfo);
    TimelineInfo.sType := VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO;
    TimelineInfo.signalSemaphoreValueCount := 1;
    TimelineInfo.pSignalSemaphoreValues := @Value;
    Info.pNext := @TimelineInfo;
    Info.signalSemaphoreCount := 1;
    Info.pSignalSemaphores := @Timeline;
  end;
  CheckVulkan(FOwner.API.vkQueueSubmit(FOwner.Queue, 1, @Info, FFence), 'vkQueueSubmit');
  FPending := True;
end;

procedure TVulkanCommands.Wait;
begin
  if not FPending then
    Exit;
  // A blocking wait can take milliseconds to wake up; short batches finish sooner.
  if FSpin > 0 then
  begin
    var Watch := TStopwatch.StartNew;
    while (FOwner.API.vkGetFenceStatus(FOwner.Device, FFence) = VK_NOT_READY) and (Watch.ElapsedTicks < FSpin *
      TStopwatch.Frequency div 1000000) do
      ;
  end;
  CheckVulkan(FOwner.API.vkWaitForFences(FOwner.Device, 1, @FFence, 1, UInt64($FFFFFFFFFFFFFFFF)), 'vkWaitForFences');
  CheckVulkan(FOwner.API.vkResetFences(FOwner.Device, 1, @FFence), 'vkResetFences');
  FPending := False;
end;

function TVulkanCommands.Done: Boolean;
begin
  if not FPending then
    Exit(True);
  var R := FOwner.API.vkGetFenceStatus(FOwner.Device, FFence);
  if R = VK_NOT_READY then
    Exit(False);
  CheckVulkan(R, 'vkGetFenceStatus');
  Wait;
  Result := True;
end;

procedure TVulkanCommands.Run;
begin
  Submit;
  Wait;
end;

function TVulkanCommands.Elapsed(First, Last: Cardinal): Double;
var
  Stamps: array[0..1] of UInt64;
begin
  Result := 0;
  if (First >= FQueryCount) or (Last >= FQueryCount) then
    Exit;
  var API := FOwner.API;
  if API.vkGetQueryPoolResults(FOwner.Device, FQueries, First, 1, 8, @Stamps[0], 8, VK_QUERY_RESULT_64_BIT) <>
    VK_SUCCESS then
    Exit;
  if API.vkGetQueryPoolResults(FOwner.Device, FQueries, Last, 1, 8, @Stamps[1], 8, VK_QUERY_RESULT_64_BIT) <>
    VK_SUCCESS then
    Exit;
  Result := (Stamps[1] - Stamps[0]) * Double(FOwner.Properties.limits.timestampPeriod);
end;

end.
