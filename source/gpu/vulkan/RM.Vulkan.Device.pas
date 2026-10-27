unit RM.Vulkan.Device;

// Host device services, independent of FMX. Match the other API by DXGI LUID
// on Windows or by device and driver UUID on Linux.
// Android selects AHardwareBuffer/FOREIGN-capable devices without UUID assumptions.
interface

uses System.SysUtils, RM.Vulkan.Bindings, RM.Vulkan.Loader;

type
  TVulkanUUID = array[0..15] of Byte;

  TVulkanDevice = class
  private
    FAPI: TVulkanAPI;
    FInstance: VkInstance;
    FPhysicalDevice: VkPhysicalDevice;
    FHandle: VkDevice;
    FQueue: VkQueue;
    FQueueFamily: Cardinal;
    FName: string;
    FMemory: VkPhysicalDeviceMemoryProperties;
    {$IFDEF MSWINDOWS}
    procedure SelectAdapter(AdapterLUID: UInt64);
    {$ELSEIF Defined(LINUX)}
    procedure SelectAdapter(const DeviceUUID, DriverUUID: TVulkanUUID);
    {$ELSEIF Defined(ANDROID)}
    procedure SelectAdapter;
    {$ENDIF}
    procedure CreateLogicalDevice;
  public
    {$IFDEF MSWINDOWS}
    constructor Create(AdapterLUID: UInt64);
    {$ELSEIF Defined(LINUX)}
    constructor Create(const DeviceUUID, DriverUUID: TVulkanUUID);
    {$ELSEIF Defined(ANDROID)}
    constructor Create;
    {$ENDIF}
    destructor Destroy; override;
    procedure WaitIdle;
    function MemoryType(Bits: Cardinal): Cardinal;
    property API: TVulkanAPI read FAPI;
    property Handle: VkDevice read FHandle;
    property PhysicalDevice: VkPhysicalDevice read FPhysicalDevice;
    property Queue: VkQueue read FQueue;
    property QueueFamily: Cardinal read FQueueFamily;
    property Name: string read FName;
  end;

implementation

{$IFDEF MSWINDOWS}
constructor TVulkanDevice.Create(AdapterLUID: UInt64);
{$ELSEIF Defined(LINUX)}
constructor TVulkanDevice.Create(const DeviceUUID, DriverUUID: TVulkanUUID);
{$ELSEIF Defined(ANDROID)}
constructor TVulkanDevice.Create;
{$ENDIF}
var
  ApplicationInfo: VkApplicationInfo;
  InstanceInfo: VkInstanceCreateInfo;
begin
  inherited Create;
  FAPI := TVulkanAPI.Create;
  ApplicationInfo := Default(VkApplicationInfo);
  ApplicationInfo.sType := VK_STRUCTURE_TYPE_APPLICATION_INFO;
  ApplicationInfo.pApplicationName := 'RetroMul GPU texture demo';
  ApplicationInfo.apiVersion := VK_API_VERSION_1_1;
  InstanceInfo := Default(VkInstanceCreateInfo);
  InstanceInfo.sType := VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  InstanceInfo.pApplicationInfo := @ApplicationInfo;
  CheckVulkan(FAPI.vkCreateInstance(@InstanceInfo, nil, @FInstance), 'vkCreateInstance (Vulkan 1.1)');
  FAPI.LoadInstance(FInstance);
  {$IFDEF MSWINDOWS}
  SelectAdapter(AdapterLUID);
  {$ELSEIF Defined(LINUX)}
  SelectAdapter(DeviceUUID, DriverUUID);
  {$ELSEIF Defined(ANDROID)}
  SelectAdapter;
  {$ENDIF}
  CreateLogicalDevice;
  FAPI.vkGetPhysicalDeviceMemoryProperties(FPhysicalDevice, @FMemory);
end;

{$IFDEF MSWINDOWS}
procedure TVulkanDevice.SelectAdapter(AdapterLUID: UInt64);
{$ELSEIF Defined(LINUX)}
procedure TVulkanDevice.SelectAdapter(const DeviceUUID, DriverUUID: TVulkanUUID);
{$ELSEIF Defined(ANDROID)}
procedure TVulkanDevice.SelectAdapter;
{$ENDIF}
var
  Count: Cardinal;
  Devices: TArray<VkPhysicalDevice>;
  Properties: VkPhysicalDeviceProperties2;
  Identity: VkPhysicalDeviceIDProperties;
  {$IFDEF MSWINDOWS}LUID: UInt64;{$ENDIF}
  {$IFDEF ANDROID}
  ExtensionCount: Cardinal;
  Extensions: TArray<VkExtensionProperties>;
  HasMemory, HasSync, HasForeign: Boolean;
  {$ENDIF}
begin
  Count := 0;
  CheckVulkan(FAPI.vkEnumeratePhysicalDevices(FInstance, @Count, nil), 'vkEnumeratePhysicalDevices');
  SetLength(Devices, Count);
  if Count <> 0 then
    CheckVulkan(FAPI.vkEnumeratePhysicalDevices(FInstance, @Count, @Devices[0]), 'vkEnumeratePhysicalDevices');
  for var Device in Devices do
  begin
    Identity := Default(VkPhysicalDeviceIDProperties);
    Identity.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES;
    Properties := Default(VkPhysicalDeviceProperties2);
    Properties.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    Properties.pNext := @Identity;
    FAPI.vkGetPhysicalDeviceProperties2(Device, @Properties);
    {$IFDEF MSWINDOWS}
    Move(Identity.deviceLUID[0], LUID, SizeOf(LUID));
    if (Identity.deviceLUIDValid <> 0) and (LUID = AdapterLUID) then
    {$ELSEIF Defined(LINUX)}
    if CompareMem(@Identity.deviceUUID[0], @DeviceUUID[0], SizeOf(DeviceUUID)) and
      CompareMem(@Identity.driverUUID[0], @DriverUUID[0], SizeOf(DriverUUID)) then
    {$ELSEIF Defined(ANDROID)}
    // AHardwareBuffer supports FOREIGN ownership without assuming that EGL and
    // Vulkan expose matching UUIDs. Choose a device supporting the whole bridge.
    ExtensionCount := 0;
    CheckVulkan(FAPI.vkEnumerateDeviceExtensionProperties(Device, nil, @ExtensionCount, nil), 'Query Android device extensions');
    SetLength(Extensions, ExtensionCount);
    if ExtensionCount <> 0 then
      CheckVulkan(FAPI.vkEnumerateDeviceExtensionProperties(Device, nil, @ExtensionCount, @Extensions[0]), 'Query Android device extensions');
    HasMemory := False;
    HasSync := False;
    HasForeign := False;
    for var Extension in Extensions do
    begin
      var Name := UTF8String(PAnsiChar(@Extension.extensionName[0]));
      HasMemory := HasMemory or (Name = 'VK_ANDROID_external_memory_android_hardware_buffer');
      HasSync := HasSync or (Name = 'VK_KHR_external_semaphore_fd');
      HasForeign := HasForeign or (Name = 'VK_EXT_queue_family_foreign');
    end;
    if HasMemory and HasSync and HasForeign then
    {$ENDIF}
    begin
      if Properties.properties.apiVersion < VK_API_VERSION_1_1 then
        raise EVulkanError.Create('The FMX adapter does not support Vulkan 1.1.');
      FPhysicalDevice := Device;
      FName := string(UTF8String(PAnsiChar(@Properties.properties.deviceName[0])));
      Exit;
    end;
  end;
  {$IFDEF ANDROID}
  raise EVulkanError.Create('No Vulkan 1.1 device supports AHardwareBuffer, semaphore FD and FOREIGN queue ownership.');
  {$ELSE}
  raise EVulkanError.Create('No Vulkan device matches the FMX GPU and driver identity.');
  {$ENDIF}
end;

procedure TVulkanDevice.CreateLogicalDevice;
const
  {$IFDEF MSWINDOWS}
  MemoryExtension: PAnsiChar = 'VK_KHR_external_memory_win32';
  {$ELSEIF Defined(LINUX)}
  MemoryExtension: PAnsiChar = 'VK_KHR_external_memory_fd';
  SemaphoreExtension: PAnsiChar = 'VK_KHR_external_semaphore_fd';
  {$ELSEIF Defined(ANDROID)}
  MemoryExtension: PAnsiChar = 'VK_ANDROID_external_memory_android_hardware_buffer';
  SemaphoreExtension: PAnsiChar = 'VK_KHR_external_semaphore_fd';
  ForeignExtension: PAnsiChar = 'VK_EXT_queue_family_foreign';
  {$ENDIF}
var
  Count: Cardinal;
  Extensions: TArray<VkExtensionProperties>;
  Families: TArray<VkQueueFamilyProperties>;
  FoundMemory, FoundQueue: Boolean;
  {$IF Defined(LINUX) or Defined(ANDROID)}FoundSemaphore: Boolean;{$ENDIF}
  {$IFDEF ANDROID}FoundForeign: Boolean;{$ENDIF}
  Priority: Single;
  QueueInfo: VkDeviceQueueCreateInfo;
  DeviceInfo: VkDeviceCreateInfo;
  {$IFDEF MSWINDOWS}Names: array[0..0] of PAnsiChar;
  {$ELSEIF Defined(ANDROID)}Names: array[0..2] of PAnsiChar;
  {$ELSE}Names: array[0..1] of PAnsiChar;{$ENDIF}
begin
  Count := 0;
  CheckVulkan(FAPI.vkEnumerateDeviceExtensionProperties(FPhysicalDevice, nil, @Count, nil), 'Enumerate device extensions');
  SetLength(Extensions, Count);
  if Count <> 0 then
    CheckVulkan(FAPI.vkEnumerateDeviceExtensionProperties(FPhysicalDevice, nil, @Count, @Extensions[0]), 'Enumerate device extensions');
  FoundMemory := False;
  {$IF Defined(LINUX) or Defined(ANDROID)}FoundSemaphore := False;{$ENDIF}
  {$IFDEF ANDROID}FoundForeign := False;{$ENDIF}
  for var Extension in Extensions do
  begin
    FoundMemory := FoundMemory or (UTF8String(PAnsiChar(@Extension.extensionName[0])) = UTF8String(MemoryExtension));
    {$IF Defined(LINUX) or Defined(ANDROID)}
    FoundSemaphore := FoundSemaphore or (UTF8String(PAnsiChar(@Extension.extensionName[0])) = UTF8String(SemaphoreExtension));
    {$ENDIF}
    {$IFDEF ANDROID}
    FoundForeign := FoundForeign or (UTF8String(PAnsiChar(@Extension.extensionName[0])) = UTF8String(ForeignExtension));
    {$ENDIF}
  end;
  if not FoundMemory then
    raise EVulkanError.Create('The FMX GPU must support ' + string(AnsiString(MemoryExtension)) + '.');
  {$IF Defined(LINUX) or Defined(ANDROID)}
  if not FoundSemaphore then
    raise EVulkanError.Create('The FMX GPU must support VK_KHR_external_semaphore_fd.');
  {$ENDIF}
  {$IFDEF ANDROID}
  if not FoundForeign then
    raise EVulkanError.Create('The Vulkan GPU must support VK_EXT_queue_family_foreign.');
  {$ENDIF}
  Count := 0;
  FAPI.vkGetPhysicalDeviceQueueFamilyProperties(FPhysicalDevice, @Count, nil);
  SetLength(Families, Count);
  if Count <> 0 then
    FAPI.vkGetPhysicalDeviceQueueFamilyProperties(FPhysicalDevice, @Count, @Families[0]);
  FoundQueue := False;
  for var I := 0 to High(Families) do
    if (Families[I].queueFlags and VK_QUEUE_GRAPHICS_BIT <> 0) and (Families[I].queueCount > 0) then
    begin
      FQueueFamily := I;
      FoundQueue := True;
      Break;
    end;
  if not FoundQueue then
    raise EVulkanError.Create('The Vulkan device has no graphics queue.');
  Priority := 1;
  QueueInfo := Default(VkDeviceQueueCreateInfo);
  QueueInfo.sType := VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  QueueInfo.queueFamilyIndex := FQueueFamily;
  QueueInfo.queueCount := 1;
  QueueInfo.pQueuePriorities := @Priority;
  Names[0] := MemoryExtension;
  {$IF Defined(LINUX) or Defined(ANDROID)}Names[1] := SemaphoreExtension;{$ENDIF}
  {$IFDEF ANDROID}Names[2] := ForeignExtension;{$ENDIF}
  DeviceInfo := Default(VkDeviceCreateInfo);
  DeviceInfo.sType := VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  DeviceInfo.queueCreateInfoCount := 1;
  DeviceInfo.pQueueCreateInfos := @QueueInfo;
  DeviceInfo.enabledExtensionCount := Length(Names);
  DeviceInfo.ppEnabledExtensionNames := @Names[0];
  CheckVulkan(FAPI.vkCreateDevice(FPhysicalDevice, @DeviceInfo, nil, @FHandle), 'vkCreateDevice');
  FAPI.LoadDevice(FHandle);
  FAPI.vkGetDeviceQueue(FHandle, FQueueFamily, 0, @FQueue);
end;

function TVulkanDevice.MemoryType(Bits: Cardinal): Cardinal;
begin
  for var I := 0 to Integer(FMemory.memoryTypeCount) - 1 do
    if (Bits and (Cardinal(1) shl I) <> 0) and
      (FMemory.memoryTypes[I].propertyFlags and VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT <> 0) then
      Exit(I);
  for var I := 0 to Integer(FMemory.memoryTypeCount) - 1 do
    if Bits and (Cardinal(1) shl I) <> 0 then
      Exit(I);
  raise EVulkanError.Create('No compatible Vulkan memory type for the shared texture.');
end;

procedure TVulkanDevice.WaitIdle;
begin
  if (FHandle <> nil) and Assigned(FAPI.vkDeviceWaitIdle) then
    CheckVulkan(FAPI.vkDeviceWaitIdle(FHandle), 'vkDeviceWaitIdle');
end;

destructor TVulkanDevice.Destroy;
begin
  if FAPI <> nil then
  begin
    if (FHandle <> nil) and Assigned(FAPI.vkDestroyDevice) then
    begin
      if Assigned(FAPI.vkDeviceWaitIdle) then
        FAPI.vkDeviceWaitIdle(FHandle);
      FAPI.vkDestroyDevice(FHandle, nil);
    end;
    if (FInstance <> nil) and Assigned(FAPI.vkDestroyInstance) then
      FAPI.vkDestroyInstance(FInstance, nil);
  end;
  FAPI.Free;
  inherited;
end;

end.
