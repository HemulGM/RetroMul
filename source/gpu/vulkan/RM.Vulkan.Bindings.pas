unit RM.Vulkan.Bindings;

// Selected Windows/Linux/Android subset, derived from Khronos Vulkan-Headers v1.4.362.
// https://github.com/KhronosGroup/Vulkan-Headers
// Copyright 2015-2026 The Khronos Group Inc. SPDX-License-Identifier: MIT
// Dispatchable handles are pointers; non-dispatchable handles remain 64-bit on Win32.

interface

{$ALIGN 8}

const
  VK_SUCCESS = 0;
  VK_TIMEOUT = 2;
  VK_ERROR_FORMAT_NOT_SUPPORTED = -11;
  VK_API_VERSION_1_1 = ( 1 shl 22) or (1 shl 12);
  VK_QUEUE_GRAPHICS_BIT = $00000001;
  VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT = $00000001;
  VK_IMAGE_TYPE_2D = 1;
  VK_IMAGE_VIEW_TYPE_2D = 1;
  VK_FORMAT_B8G8R8A8_UNORM = 44;
  VK_IMAGE_TILING_OPTIMAL = 0;
  VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT = $00000010;
  VK_IMAGE_USAGE_SAMPLED_BIT = $00000004;
  VK_IMAGE_USAGE_TRANSFER_SRC_BIT = $00000001;
  VK_SHARING_MODE_EXCLUSIVE = 0;
  VK_SAMPLE_COUNT_1_BIT = $00000001;
  VK_IMAGE_ASPECT_COLOR_BIT = $00000001;
  VK_IMAGE_LAYOUT_UNDEFINED = 0;
  VK_IMAGE_LAYOUT_GENERAL = 1;
  VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL = 2;
  VK_QUEUE_FAMILY_EXTERNAL = $FFFFFFFE;
  VK_QUEUE_FAMILY_IGNORED = $FFFFFFFF;
  VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT = $00000010;
  VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT = $00000004;
  VK_ATTACHMENT_LOAD_OP_CLEAR = 1;
  VK_ATTACHMENT_STORE_OP_STORE = 0;
  VK_ATTACHMENT_LOAD_OP_DONT_CARE = 2;
  VK_ATTACHMENT_STORE_OP_DONT_CARE = 1;
  VK_PIPELINE_BIND_POINT_GRAPHICS = 0;
  VK_SUBPASS_EXTERNAL = $FFFFFFFF;
  VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT = $00000001;
  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT = $00000400;
  VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT = $00002000;
  VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT = $00000100;
  VK_ACCESS_COLOR_ATTACHMENT_READ_BIT = $00000080;
  VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT = $00000002;
  VK_COMMAND_BUFFER_LEVEL_PRIMARY = 0;
  VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT = $00000001;
  VK_SUBPASS_CONTENTS_INLINE = 0;
  VK_SHADER_STAGE_VERTEX_BIT = $00000001;
  VK_SHADER_STAGE_FRAGMENT_BIT = $00000010;
  VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST = 3;
  VK_POLYGON_MODE_FILL = 0;
  VK_CULL_MODE_NONE = 0;
  VK_FRONT_FACE_COUNTER_CLOCKWISE = 0;
  VK_COLOR_COMPONENT_R_BIT = $00000001;
  VK_COLOR_COMPONENT_G_BIT = $00000002;
  VK_COLOR_COMPONENT_B_BIT = $00000004;
  VK_COLOR_COMPONENT_A_BIT = $00000008;
  VK_DYNAMIC_STATE_VIEWPORT = 0;
  VK_DYNAMIC_STATE_SCISSOR = 1;
  VK_STRUCTURE_TYPE_APPLICATION_INFO = 0;
  VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1;
  VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO = 2;
  VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO = 3;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 = 1000059001;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES = 1000071004;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2 = 1000059004;
  VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2 = 1000059003;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO = 1000071000;
  VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES = 1000071001;
  VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO = 1000072001;
  VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO = 14;
  VK_STRUCTURE_TYPE_IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR = 1000073000;
  VK_STRUCTURE_TYPE_MEMORY_WIN32_HANDLE_PROPERTIES_KHR = 1000073002;
  VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO = 1000127001;
  VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO = 5;
  VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO = 15;
  VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO = 38;
  VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO = 37;
  VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO = 16;
  VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO = 30;
  VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO = 18;
  VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO = 19;
  VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO = 20;
  VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO = 22;
  VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO = 23;
  VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO = 24;
  VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO = 26;
  VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO = 27;
  VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO = 28;
  VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO = 39;
  VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO = 40;
  VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO = 42;
  VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO = 43;
  VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER = 45;
  VK_STRUCTURE_TYPE_FENCE_CREATE_INFO = 8;
  VK_STRUCTURE_TYPE_SUBMIT_INFO = 4;
  VK_FORMAT_R8G8B8A8_UNORM = 37;
  VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT = $00000001;
  VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT = $00000002;
  VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT = $00000001;
  VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT = $00000001;
  VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO = 1000072002;
  VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR = 1000074002;
  VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO = 1000077000;
  VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO = 9;
  VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR = 1000079001;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO = 1000076000;
  VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES = 1000076001;
  VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID = $00000400;
  VK_QUEUE_FAMILY_FOREIGN_EXT = $FFFFFFFD;
  VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID = 1000129001;
  VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID = 1000129002;
  VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_USAGE_ANDROID = 1000129000;
  VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID = 1000129003;
  VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR = 1000079000;
  VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT = $00000010;
  VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT = $00000002;
  VK_SEMAPHORE_IMPORT_TEMPORARY_BIT = $00000001;
  VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT = $00000080;
  VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT = $00000001;
  VK_LUID_SIZE = 8;
  VK_MAX_EXTENSION_NAME_SIZE = 256;
  VK_MAX_MEMORY_HEAPS = 16;
  VK_MAX_MEMORY_TYPES = 32;
  VK_MAX_PHYSICAL_DEVICE_NAME_SIZE = 256;
  VK_UUID_SIZE = 16;

type
  PVkAndroidHardwareBufferPropertiesANDROID = ^VkAndroidHardwareBufferPropertiesANDROID;

  PVkApplicationInfo = ^VkApplicationInfo;

  PVkAttachmentDescription = ^VkAttachmentDescription;

  PVkAttachmentReference = ^VkAttachmentReference;

  PVkBufferMemoryBarrier = ^VkBufferMemoryBarrier;

  PVkClearValue = ^VkClearValue;

  PVkCommandBuffer = ^VkCommandBuffer;

  PVkCommandBufferAllocateInfo = ^VkCommandBufferAllocateInfo;

  PVkCommandBufferBeginInfo = ^VkCommandBufferBeginInfo;

  PVkCommandBufferInheritanceInfo = ^VkCommandBufferInheritanceInfo;

  PVkCommandPool = ^VkCommandPool;

  PVkCommandPoolCreateInfo = ^VkCommandPoolCreateInfo;

  PVkDescriptorSetLayout = ^VkDescriptorSetLayout;

  PVkDevice = ^VkDevice;

  PVkDeviceCreateInfo = ^VkDeviceCreateInfo;

  PVkDeviceMemory = ^VkDeviceMemory;

  PVkDeviceQueueCreateInfo = ^VkDeviceQueueCreateInfo;

  PVkDynamicState = ^VkDynamicState;

  PVkExtensionProperties = ^VkExtensionProperties;

  PVkExternalSemaphoreProperties = ^VkExternalSemaphoreProperties;

  PVkFence = ^VkFence;

  PVkFenceCreateInfo = ^VkFenceCreateInfo;

  PVkFramebuffer = ^VkFramebuffer;

  PVkFramebufferCreateInfo = ^VkFramebufferCreateInfo;

  PVkGraphicsPipelineCreateInfo = ^VkGraphicsPipelineCreateInfo;

  PVkImage = ^VkImage;

  PVkImageCreateInfo = ^VkImageCreateInfo;

  PVkImageFormatProperties2 = ^VkImageFormatProperties2;

  PVkImageMemoryBarrier = ^VkImageMemoryBarrier;

  PVkImageView = ^VkImageView;

  PVkImageViewCreateInfo = ^VkImageViewCreateInfo;

  PVkImportSemaphoreFdInfoKHR = ^VkImportSemaphoreFdInfoKHR;

  PVkInstance = ^VkInstance;

  PVkInstanceCreateInfo = ^VkInstanceCreateInfo;

  PVkMemoryAllocateInfo = ^VkMemoryAllocateInfo;

  PVkMemoryBarrier = ^VkMemoryBarrier;

  PVkMemoryGetFdInfoKHR = ^VkMemoryGetFdInfoKHR;

  PVkMemoryRequirements = ^VkMemoryRequirements;

  PVkMemoryWin32HandlePropertiesKHR = ^VkMemoryWin32HandlePropertiesKHR;

  PVkPhysicalDevice = ^VkPhysicalDevice;

  PVkPhysicalDeviceExternalSemaphoreInfo = ^VkPhysicalDeviceExternalSemaphoreInfo;

  PVkPhysicalDeviceFeatures = ^VkPhysicalDeviceFeatures;

  PVkPhysicalDeviceImageFormatInfo2 = ^VkPhysicalDeviceImageFormatInfo2;

  PVkPhysicalDeviceMemoryProperties = ^VkPhysicalDeviceMemoryProperties;

  PVkPhysicalDeviceProperties2 = ^VkPhysicalDeviceProperties2;

  PVkPipeline = ^VkPipeline;

  PVkPipelineColorBlendAttachmentState = ^VkPipelineColorBlendAttachmentState;

  PVkPipelineColorBlendStateCreateInfo = ^VkPipelineColorBlendStateCreateInfo;

  PVkPipelineDepthStencilStateCreateInfo = ^VkPipelineDepthStencilStateCreateInfo;

  PVkPipelineDynamicStateCreateInfo = ^VkPipelineDynamicStateCreateInfo;

  PVkPipelineInputAssemblyStateCreateInfo = ^VkPipelineInputAssemblyStateCreateInfo;

  PVkPipelineLayout = ^VkPipelineLayout;

  PVkPipelineLayoutCreateInfo = ^VkPipelineLayoutCreateInfo;

  PVkPipelineMultisampleStateCreateInfo = ^VkPipelineMultisampleStateCreateInfo;

  PVkPipelineRasterizationStateCreateInfo = ^VkPipelineRasterizationStateCreateInfo;

  PVkPipelineShaderStageCreateInfo = ^VkPipelineShaderStageCreateInfo;

  PVkPipelineStageFlags = ^VkPipelineStageFlags;

  PVkPipelineTessellationStateCreateInfo = ^VkPipelineTessellationStateCreateInfo;

  PVkPipelineVertexInputStateCreateInfo = ^VkPipelineVertexInputStateCreateInfo;

  PVkPipelineViewportStateCreateInfo = ^VkPipelineViewportStateCreateInfo;

  PVkPushConstantRange = ^VkPushConstantRange;

  PVkQueue = ^VkQueue;

  PVkQueueFamilyProperties = ^VkQueueFamilyProperties;

  PVkRect2D = ^VkRect2D;

  PVkRenderPass = ^VkRenderPass;

  PVkRenderPassBeginInfo = ^VkRenderPassBeginInfo;

  PVkRenderPassCreateInfo = ^VkRenderPassCreateInfo;

  PVkSampleMask = ^VkSampleMask;

  PVkSemaphore = ^VkSemaphore;

  PVkSemaphoreCreateInfo = ^VkSemaphoreCreateInfo;

  PVkSemaphoreGetFdInfoKHR = ^VkSemaphoreGetFdInfoKHR;

  PVkShaderModule = ^VkShaderModule;

  PVkShaderModuleCreateInfo = ^VkShaderModuleCreateInfo;

  PVkSubmitInfo = ^VkSubmitInfo;

  PVkSubpassDependency = ^VkSubpassDependency;

  PVkSubpassDescription = ^VkSubpassDescription;

  PVkVertexInputAttributeDescription = ^VkVertexInputAttributeDescription;

  PVkVertexInputBindingDescription = ^VkVertexInputBindingDescription;

  PVkViewport = ^VkViewport;

  VkStructureType = Integer;

  VkBool32 = Cardinal;

  VkPhysicalDeviceIDProperties = record
    sType: VkStructureType;
    pNext: Pointer;
    deviceUUID: array[0..VK_UUID_SIZE - 1] of Byte;
    driverUUID: array[0..VK_UUID_SIZE - 1] of Byte;
    deviceLUID: array[0..VK_LUID_SIZE - 1] of Byte;
    deviceNodeMask: Cardinal;
    deviceLUIDValid: VkBool32;
  end;

  VkExternalMemoryHandleTypeFlagBits = Integer;

  VkPhysicalDeviceExternalImageFormatInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    handleType: VkExternalMemoryHandleTypeFlagBits;
  end;

  VkFlags = Cardinal;

  VkExternalMemoryFeatureFlags = VkFlags;

  VkExternalMemoryHandleTypeFlags = VkFlags;

  VkExternalMemoryProperties = record
    externalMemoryFeatures: VkExternalMemoryFeatureFlags;
    exportFromImportedHandleTypes: VkExternalMemoryHandleTypeFlags;
    compatibleHandleTypes: VkExternalMemoryHandleTypeFlags;
  end;

  VkExternalImageFormatProperties = record
    sType: VkStructureType;
    pNext: Pointer;
    externalMemoryProperties: VkExternalMemoryProperties;
  end;

  VkExternalMemoryImageCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    handleTypes: VkExternalMemoryHandleTypeFlags;
  end;

  VkImportMemoryWin32HandleInfoKHR = record
    sType: VkStructureType;
    pNext: Pointer;
    handleType: VkExternalMemoryHandleTypeFlagBits;
    handle: NativeUInt;
    name: PWideChar;
  end;

  VkImage = UInt64;

  VkBuffer = UInt64;

  VkMemoryDedicatedAllocateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    image: VkImage;
    buffer: VkBuffer;
  end;

  VkExportMemoryAllocateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    handleTypes: VkExternalMemoryHandleTypeFlags;
  end;

  VkExternalSemaphoreHandleTypeFlags = VkFlags;

  VkExportSemaphoreCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    handleTypes: VkExternalSemaphoreHandleTypeFlags;
  end;

  VkFormat = Integer;

  VkFormatFeatureFlags = VkFlags;

  VkComponentSwizzle = Integer;

  VkComponentMapping = record
    r: VkComponentSwizzle;
    g: VkComponentSwizzle;
    b: VkComponentSwizzle;
    a: VkComponentSwizzle;
  end;

  VkSamplerYcbcrModelConversion = Integer;

  VkSamplerYcbcrRange = Integer;

  VkChromaLocation = Integer;

  VkAndroidHardwareBufferFormatPropertiesANDROID = record
    sType: VkStructureType;
    pNext: Pointer;
    format: VkFormat;
    externalFormat: UInt64;
    formatFeatures: VkFormatFeatureFlags;
    samplerYcbcrConversionComponents: VkComponentMapping;
    suggestedYcbcrModel: VkSamplerYcbcrModelConversion;
    suggestedYcbcrRange: VkSamplerYcbcrRange;
    suggestedXChromaOffset: VkChromaLocation;
    suggestedYChromaOffset: VkChromaLocation;
  end;

  VkAndroidHardwareBufferUsageANDROID = record
    sType: VkStructureType;
    pNext: Pointer;
    androidHardwareBufferUsage: UInt64;
  end;

  VkImportAndroidHardwareBufferInfoANDROID = record
    sType: VkStructureType;
    pNext: Pointer;
    buffer: Pointer;
  end;

  VkInstance = Pointer;

  PFN_vkVoidFunction = procedure; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  VkDevice = Pointer;

  VkInstanceCreateFlags = VkFlags;

  VkApplicationInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    pApplicationName: PAnsiChar;
    applicationVersion: Cardinal;
    pEngineName: PAnsiChar;
    engineVersion: Cardinal;
    apiVersion: Cardinal;
  end;

  VkInstanceCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkInstanceCreateFlags;
    pApplicationInfo: PVkApplicationInfo;
    enabledLayerCount: Cardinal;
    ppEnabledLayerNames: PPAnsiChar;
    enabledExtensionCount: Cardinal;
    ppEnabledExtensionNames: PPAnsiChar;
  end;

  VkResult = Integer;

  VkPhysicalDevice = Pointer;

  VkPhysicalDeviceType = Integer;

  VkDeviceSize = UInt64;

  VkSampleCountFlags = VkFlags;

  VkPhysicalDeviceLimits = record
    maxImageDimension1D: Cardinal;
    maxImageDimension2D: Cardinal;
    maxImageDimension3D: Cardinal;
    maxImageDimensionCube: Cardinal;
    maxImageArrayLayers: Cardinal;
    maxTexelBufferElements: Cardinal;
    maxUniformBufferRange: Cardinal;
    maxStorageBufferRange: Cardinal;
    maxPushConstantsSize: Cardinal;
    maxMemoryAllocationCount: Cardinal;
    maxSamplerAllocationCount: Cardinal;
    bufferImageGranularity: VkDeviceSize;
    sparseAddressSpaceSize: VkDeviceSize;
    maxBoundDescriptorSets: Cardinal;
    maxPerStageDescriptorSamplers: Cardinal;
    maxPerStageDescriptorUniformBuffers: Cardinal;
    maxPerStageDescriptorStorageBuffers: Cardinal;
    maxPerStageDescriptorSampledImages: Cardinal;
    maxPerStageDescriptorStorageImages: Cardinal;
    maxPerStageDescriptorInputAttachments: Cardinal;
    maxPerStageResources: Cardinal;
    maxDescriptorSetSamplers: Cardinal;
    maxDescriptorSetUniformBuffers: Cardinal;
    maxDescriptorSetUniformBuffersDynamic: Cardinal;
    maxDescriptorSetStorageBuffers: Cardinal;
    maxDescriptorSetStorageBuffersDynamic: Cardinal;
    maxDescriptorSetSampledImages: Cardinal;
    maxDescriptorSetStorageImages: Cardinal;
    maxDescriptorSetInputAttachments: Cardinal;
    maxVertexInputAttributes: Cardinal;
    maxVertexInputBindings: Cardinal;
    maxVertexInputAttributeOffset: Cardinal;
    maxVertexInputBindingStride: Cardinal;
    maxVertexOutputComponents: Cardinal;
    maxTessellationGenerationLevel: Cardinal;
    maxTessellationPatchSize: Cardinal;
    maxTessellationControlPerVertexInputComponents: Cardinal;
    maxTessellationControlPerVertexOutputComponents: Cardinal;
    maxTessellationControlPerPatchOutputComponents: Cardinal;
    maxTessellationControlTotalOutputComponents: Cardinal;
    maxTessellationEvaluationInputComponents: Cardinal;
    maxTessellationEvaluationOutputComponents: Cardinal;
    maxGeometryShaderInvocations: Cardinal;
    maxGeometryInputComponents: Cardinal;
    maxGeometryOutputComponents: Cardinal;
    maxGeometryOutputVertices: Cardinal;
    maxGeometryTotalOutputComponents: Cardinal;
    maxFragmentInputComponents: Cardinal;
    maxFragmentOutputAttachments: Cardinal;
    maxFragmentDualSrcAttachments: Cardinal;
    maxFragmentCombinedOutputResources: Cardinal;
    maxComputeSharedMemorySize: Cardinal;
    maxComputeWorkGroupCount: array[0..3 - 1] of Cardinal;
    maxComputeWorkGroupInvocations: Cardinal;
    maxComputeWorkGroupSize: array[0..3 - 1] of Cardinal;
    subPixelPrecisionBits: Cardinal;
    subTexelPrecisionBits: Cardinal;
    mipmapPrecisionBits: Cardinal;
    maxDrawIndexedIndexValue: Cardinal;
    maxDrawIndirectCount: Cardinal;
    maxSamplerLodBias: Single;
    maxSamplerAnisotropy: Single;
    maxViewports: Cardinal;
    maxViewportDimensions: array[0..2 - 1] of Cardinal;
    viewportBoundsRange: array[0..2 - 1] of Single;
    viewportSubPixelBits: Cardinal;
    minMemoryMapAlignment: NativeUInt;
    minTexelBufferOffsetAlignment: VkDeviceSize;
    minUniformBufferOffsetAlignment: VkDeviceSize;
    minStorageBufferOffsetAlignment: VkDeviceSize;
    minTexelOffset: Integer;
    maxTexelOffset: Cardinal;
    minTexelGatherOffset: Integer;
    maxTexelGatherOffset: Cardinal;
    minInterpolationOffset: Single;
    maxInterpolationOffset: Single;
    subPixelInterpolationOffsetBits: Cardinal;
    maxFramebufferWidth: Cardinal;
    maxFramebufferHeight: Cardinal;
    maxFramebufferLayers: Cardinal;
    framebufferColorSampleCounts: VkSampleCountFlags;
    framebufferDepthSampleCounts: VkSampleCountFlags;
    framebufferStencilSampleCounts: VkSampleCountFlags;
    framebufferNoAttachmentsSampleCounts: VkSampleCountFlags;
    maxColorAttachments: Cardinal;
    sampledImageColorSampleCounts: VkSampleCountFlags;
    sampledImageIntegerSampleCounts: VkSampleCountFlags;
    sampledImageDepthSampleCounts: VkSampleCountFlags;
    sampledImageStencilSampleCounts: VkSampleCountFlags;
    storageImageSampleCounts: VkSampleCountFlags;
    maxSampleMaskWords: Cardinal;
    timestampComputeAndGraphics: VkBool32;
    timestampPeriod: Single;
    maxClipDistances: Cardinal;
    maxCullDistances: Cardinal;
    maxCombinedClipAndCullDistances: Cardinal;
    discreteQueuePriorities: Cardinal;
    pointSizeRange: array[0..2 - 1] of Single;
    lineWidthRange: array[0..2 - 1] of Single;
    pointSizeGranularity: Single;
    lineWidthGranularity: Single;
    strictLines: VkBool32;
    standardSampleLocations: VkBool32;
    optimalBufferCopyOffsetAlignment: VkDeviceSize;
    optimalBufferCopyRowPitchAlignment: VkDeviceSize;
    nonCoherentAtomSize: VkDeviceSize;
  end;

  VkPhysicalDeviceSparseProperties = record
    residencyStandard2DBlockShape: VkBool32;
    residencyStandard2DMultisampleBlockShape: VkBool32;
    residencyStandard3DBlockShape: VkBool32;
    residencyAlignedMipSize: VkBool32;
    residencyNonResidentStrict: VkBool32;
  end;

  VkPhysicalDeviceProperties = record
    apiVersion: Cardinal;
    driverVersion: Cardinal;
    vendorID: Cardinal;
    deviceID: Cardinal;
    deviceType: VkPhysicalDeviceType;
    deviceName: array[0..VK_MAX_PHYSICAL_DEVICE_NAME_SIZE - 1] of AnsiChar;
    pipelineCacheUUID: array[0..VK_UUID_SIZE - 1] of Byte;
    limits: VkPhysicalDeviceLimits;
    sparseProperties: VkPhysicalDeviceSparseProperties;
  end;

  VkPhysicalDeviceProperties2 = record
    sType: VkStructureType;
    pNext: Pointer;
    properties: VkPhysicalDeviceProperties;
  end;

  VkQueueFlags = VkFlags;

  VkExtent3D = record
    width: Cardinal;
    height: Cardinal;
    depth: Cardinal;
  end;

  VkQueueFamilyProperties = record
    queueFlags: VkQueueFlags;
    queueCount: Cardinal;
    timestampValidBits: Cardinal;
    minImageTransferGranularity: VkExtent3D;
  end;

  VkMemoryPropertyFlags = VkFlags;

  VkMemoryType = record
    propertyFlags: VkMemoryPropertyFlags;
    heapIndex: Cardinal;
  end;

  VkMemoryHeapFlags = VkFlags;

  VkMemoryHeap = record
    size: VkDeviceSize;
    flags: VkMemoryHeapFlags;
  end;

  VkPhysicalDeviceMemoryProperties = record
    memoryTypeCount: Cardinal;
    memoryTypes: array[0..VK_MAX_MEMORY_TYPES - 1] of VkMemoryType;
    memoryHeapCount: Cardinal;
    memoryHeaps: array[0..VK_MAX_MEMORY_HEAPS - 1] of VkMemoryHeap;
  end;

  VkExtensionProperties = record
    extensionName: array[0..VK_MAX_EXTENSION_NAME_SIZE - 1] of AnsiChar;
    specVersion: Cardinal;
  end;

  VkImageType = Integer;

  VkImageTiling = Integer;

  VkImageUsageFlags = VkFlags;

  VkImageCreateFlags = VkFlags;

  VkPhysicalDeviceImageFormatInfo2 = record
    sType: VkStructureType;
    pNext: Pointer;
    format: VkFormat;
    &type: VkImageType;
    tiling: VkImageTiling;
    usage: VkImageUsageFlags;
    flags: VkImageCreateFlags;
  end;

  VkImageFormatProperties = record
    maxExtent: VkExtent3D;
    maxMipLevels: Cardinal;
    maxArrayLayers: Cardinal;
    sampleCounts: VkSampleCountFlags;
    maxResourceSize: VkDeviceSize;
  end;

  VkImageFormatProperties2 = record
    sType: VkStructureType;
    pNext: Pointer;
    imageFormatProperties: VkImageFormatProperties;
  end;

  VkDeviceCreateFlags = VkFlags;

  VkDeviceQueueCreateFlags = VkFlags;

  VkDeviceQueueCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkDeviceQueueCreateFlags;
    queueFamilyIndex: Cardinal;
    queueCount: Cardinal;
    pQueuePriorities: PSingle;
  end;

  VkPhysicalDeviceFeatures = record
    robustBufferAccess: VkBool32;
    fullDrawIndexUint32: VkBool32;
    imageCubeArray: VkBool32;
    independentBlend: VkBool32;
    geometryShader: VkBool32;
    tessellationShader: VkBool32;
    sampleRateShading: VkBool32;
    dualSrcBlend: VkBool32;
    logicOp: VkBool32;
    multiDrawIndirect: VkBool32;
    drawIndirectFirstInstance: VkBool32;
    depthClamp: VkBool32;
    depthBiasClamp: VkBool32;
    fillModeNonSolid: VkBool32;
    depthBounds: VkBool32;
    wideLines: VkBool32;
    largePoints: VkBool32;
    alphaToOne: VkBool32;
    multiViewport: VkBool32;
    samplerAnisotropy: VkBool32;
    textureCompressionETC2: VkBool32;
    textureCompressionASTC_LDR: VkBool32;
    textureCompressionBC: VkBool32;
    occlusionQueryPrecise: VkBool32;
    pipelineStatisticsQuery: VkBool32;
    vertexPipelineStoresAndAtomics: VkBool32;
    fragmentStoresAndAtomics: VkBool32;
    shaderTessellationAndGeometryPointSize: VkBool32;
    shaderImageGatherExtended: VkBool32;
    shaderStorageImageExtendedFormats: VkBool32;
    shaderStorageImageMultisample: VkBool32;
    shaderStorageImageReadWithoutFormat: VkBool32;
    shaderStorageImageWriteWithoutFormat: VkBool32;
    shaderUniformBufferArrayDynamicIndexing: VkBool32;
    shaderSampledImageArrayDynamicIndexing: VkBool32;
    shaderStorageBufferArrayDynamicIndexing: VkBool32;
    shaderStorageImageArrayDynamicIndexing: VkBool32;
    shaderClipDistance: VkBool32;
    shaderCullDistance: VkBool32;
    shaderFloat64: VkBool32;
    shaderInt64: VkBool32;
    shaderInt16: VkBool32;
    shaderResourceResidency: VkBool32;
    shaderResourceMinLod: VkBool32;
    sparseBinding: VkBool32;
    sparseResidencyBuffer: VkBool32;
    sparseResidencyImage2D: VkBool32;
    sparseResidencyImage3D: VkBool32;
    sparseResidency2Samples: VkBool32;
    sparseResidency4Samples: VkBool32;
    sparseResidency8Samples: VkBool32;
    sparseResidency16Samples: VkBool32;
    sparseResidencyAliased: VkBool32;
    variableMultisampleRate: VkBool32;
    inheritedQueries: VkBool32;
  end;

  VkDeviceCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkDeviceCreateFlags;
    queueCreateInfoCount: Cardinal;
    pQueueCreateInfos: PVkDeviceQueueCreateInfo;
    enabledLayerCount: Cardinal;
    ppEnabledLayerNames: PPAnsiChar;
    enabledExtensionCount: Cardinal;
    ppEnabledExtensionNames: PPAnsiChar;
    pEnabledFeatures: PVkPhysicalDeviceFeatures;
  end;

  VkQueue = Pointer;

  VkSampleCountFlagBits = Integer;

  VkSharingMode = Integer;

  VkImageLayout = Integer;

  VkImageCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkImageCreateFlags;
    imageType: VkImageType;
    format: VkFormat;
    extent: VkExtent3D;
    mipLevels: Cardinal;
    arrayLayers: Cardinal;
    samples: VkSampleCountFlagBits;
    tiling: VkImageTiling;
    usage: VkImageUsageFlags;
    sharingMode: VkSharingMode;
    queueFamilyIndexCount: Cardinal;
    pQueueFamilyIndices: PCardinal;
    initialLayout: VkImageLayout;
  end;

  VkMemoryRequirements = record
    size: VkDeviceSize;
    alignment: VkDeviceSize;
    memoryTypeBits: Cardinal;
  end;

  VkMemoryWin32HandlePropertiesKHR = record
    sType: VkStructureType;
    pNext: Pointer;
    memoryTypeBits: Cardinal;
  end;

  VkMemoryAllocateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    allocationSize: VkDeviceSize;
    memoryTypeIndex: Cardinal;
  end;

  VkDeviceMemory = UInt64;

  VkImageViewCreateFlags = VkFlags;

  VkImageViewType = Integer;

  VkImageAspectFlags = VkFlags;

  VkImageSubresourceRange = record
    aspectMask: VkImageAspectFlags;
    baseMipLevel: Cardinal;
    levelCount: Cardinal;
    baseArrayLayer: Cardinal;
    layerCount: Cardinal;
  end;

  VkImageViewCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkImageViewCreateFlags;
    image: VkImage;
    viewType: VkImageViewType;
    format: VkFormat;
    components: VkComponentMapping;
    subresourceRange: VkImageSubresourceRange;
  end;

  VkImageView = UInt64;

  VkRenderPassCreateFlags = VkFlags;

  VkAttachmentDescriptionFlags = VkFlags;

  VkAttachmentLoadOp = Integer;

  VkAttachmentStoreOp = Integer;

  VkAttachmentDescription = record
    flags: VkAttachmentDescriptionFlags;
    format: VkFormat;
    samples: VkSampleCountFlagBits;
    loadOp: VkAttachmentLoadOp;
    storeOp: VkAttachmentStoreOp;
    stencilLoadOp: VkAttachmentLoadOp;
    stencilStoreOp: VkAttachmentStoreOp;
    initialLayout: VkImageLayout;
    finalLayout: VkImageLayout;
  end;

  VkSubpassDescriptionFlags = VkFlags;

  VkPipelineBindPoint = Integer;

  VkAttachmentReference = record
    attachment: Cardinal;
    layout: VkImageLayout;
  end;

  VkSubpassDescription = record
    flags: VkSubpassDescriptionFlags;
    pipelineBindPoint: VkPipelineBindPoint;
    inputAttachmentCount: Cardinal;
    pInputAttachments: PVkAttachmentReference;
    colorAttachmentCount: Cardinal;
    pColorAttachments: PVkAttachmentReference;
    pResolveAttachments: PVkAttachmentReference;
    pDepthStencilAttachment: PVkAttachmentReference;
    preserveAttachmentCount: Cardinal;
    pPreserveAttachments: PCardinal;
  end;

  VkPipelineStageFlags = VkFlags;

  VkAccessFlags = VkFlags;

  VkDependencyFlags = VkFlags;

  VkSubpassDependency = record
    srcSubpass: Cardinal;
    dstSubpass: Cardinal;
    srcStageMask: VkPipelineStageFlags;
    dstStageMask: VkPipelineStageFlags;
    srcAccessMask: VkAccessFlags;
    dstAccessMask: VkAccessFlags;
    dependencyFlags: VkDependencyFlags;
  end;

  VkRenderPassCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkRenderPassCreateFlags;
    attachmentCount: Cardinal;
    pAttachments: PVkAttachmentDescription;
    subpassCount: Cardinal;
    pSubpasses: PVkSubpassDescription;
    dependencyCount: Cardinal;
    pDependencies: PVkSubpassDependency;
  end;

  VkRenderPass = UInt64;

  VkFramebufferCreateFlags = VkFlags;

  VkFramebufferCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkFramebufferCreateFlags;
    renderPass: VkRenderPass;
    attachmentCount: Cardinal;
    pAttachments: PVkImageView;
    width: Cardinal;
    height: Cardinal;
    layers: Cardinal;
  end;

  VkFramebuffer = UInt64;

  VkShaderModuleCreateFlags = VkFlags;

  VkShaderModuleCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkShaderModuleCreateFlags;
    codeSize: NativeUInt;
    pCode: PCardinal;
  end;

  VkShaderModule = UInt64;

  VkPipelineLayoutCreateFlags = VkFlags;

  VkDescriptorSetLayout = UInt64;

  VkShaderStageFlags = VkFlags;

  VkPushConstantRange = record
    stageFlags: VkShaderStageFlags;
    offset: Cardinal;
    size: Cardinal;
  end;

  VkPipelineLayoutCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineLayoutCreateFlags;
    setLayoutCount: Cardinal;
    pSetLayouts: PVkDescriptorSetLayout;
    pushConstantRangeCount: Cardinal;
    pPushConstantRanges: PVkPushConstantRange;
  end;

  VkPipelineLayout = UInt64;

  VkPipelineCache = UInt64;

  VkPipelineCreateFlags = VkFlags;

  VkPipelineShaderStageCreateFlags = VkFlags;

  VkShaderStageFlagBits = Integer;

  VkPipelineShaderStageCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineShaderStageCreateFlags;
    stage: VkShaderStageFlagBits;
    module: VkShaderModule;
    pName: PAnsiChar;
    pSpecializationInfo: Pointer;
  end;

  VkPipelineVertexInputStateCreateFlags = VkFlags;

  VkVertexInputRate = Integer;

  VkVertexInputBindingDescription = record
    binding: Cardinal;
    stride: Cardinal;
    inputRate: VkVertexInputRate;
  end;

  VkVertexInputAttributeDescription = record
    location: Cardinal;
    binding: Cardinal;
    format: VkFormat;
    offset: Cardinal;
  end;

  VkPipelineVertexInputStateCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineVertexInputStateCreateFlags;
    vertexBindingDescriptionCount: Cardinal;
    pVertexBindingDescriptions: PVkVertexInputBindingDescription;
    vertexAttributeDescriptionCount: Cardinal;
    pVertexAttributeDescriptions: PVkVertexInputAttributeDescription;
  end;

  VkPipelineInputAssemblyStateCreateFlags = VkFlags;

  VkPrimitiveTopology = Integer;

  VkPipelineInputAssemblyStateCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineInputAssemblyStateCreateFlags;
    topology: VkPrimitiveTopology;
    primitiveRestartEnable: VkBool32;
  end;

  VkPipelineTessellationStateCreateFlags = VkFlags;

  VkPipelineTessellationStateCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineTessellationStateCreateFlags;
    patchControlPoints: Cardinal;
  end;

  VkPipelineViewportStateCreateFlags = VkFlags;

  VkViewport = record
    x: Single;
    y: Single;
    width: Single;
    height: Single;
    minDepth: Single;
    maxDepth: Single;
  end;

  VkOffset2D = record
    x: Integer;
    y: Integer;
  end;

  VkExtent2D = record
    width: Cardinal;
    height: Cardinal;
  end;

  VkRect2D = record
    offset: VkOffset2D;
    extent: VkExtent2D;
  end;

  VkPipelineViewportStateCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineViewportStateCreateFlags;
    viewportCount: Cardinal;
    pViewports: PVkViewport;
    scissorCount: Cardinal;
    pScissors: PVkRect2D;
  end;

  VkPipelineRasterizationStateCreateFlags = VkFlags;

  VkPolygonMode = Integer;

  VkCullModeFlags = VkFlags;

  VkFrontFace = Integer;

  VkPipelineRasterizationStateCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineRasterizationStateCreateFlags;
    depthClampEnable: VkBool32;
    rasterizerDiscardEnable: VkBool32;
    polygonMode: VkPolygonMode;
    cullMode: VkCullModeFlags;
    frontFace: VkFrontFace;
    depthBiasEnable: VkBool32;
    depthBiasConstantFactor: Single;
    depthBiasClamp: Single;
    depthBiasSlopeFactor: Single;
    lineWidth: Single;
  end;

  VkPipelineMultisampleStateCreateFlags = VkFlags;

  VkSampleMask = Cardinal;

  VkPipelineMultisampleStateCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineMultisampleStateCreateFlags;
    rasterizationSamples: VkSampleCountFlagBits;
    sampleShadingEnable: VkBool32;
    minSampleShading: Single;
    pSampleMask: PVkSampleMask;
    alphaToCoverageEnable: VkBool32;
    alphaToOneEnable: VkBool32;
  end;

  VkPipelineDepthStencilStateCreateFlags = VkFlags;

  VkCompareOp = Integer;

  VkStencilOp = Integer;

  VkStencilOpState = record
    failOp: VkStencilOp;
    passOp: VkStencilOp;
    depthFailOp: VkStencilOp;
    compareOp: VkCompareOp;
    compareMask: Cardinal;
    writeMask: Cardinal;
    reference: Cardinal;
  end;

  VkPipelineDepthStencilStateCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineDepthStencilStateCreateFlags;
    depthTestEnable: VkBool32;
    depthWriteEnable: VkBool32;
    depthCompareOp: VkCompareOp;
    depthBoundsTestEnable: VkBool32;
    stencilTestEnable: VkBool32;
    front: VkStencilOpState;
    back: VkStencilOpState;
    minDepthBounds: Single;
    maxDepthBounds: Single;
  end;

  VkPipelineColorBlendStateCreateFlags = VkFlags;

  VkLogicOp = Integer;

  VkBlendFactor = Integer;

  VkBlendOp = Integer;

  VkColorComponentFlags = VkFlags;

  VkPipelineColorBlendAttachmentState = record
    blendEnable: VkBool32;
    srcColorBlendFactor: VkBlendFactor;
    dstColorBlendFactor: VkBlendFactor;
    colorBlendOp: VkBlendOp;
    srcAlphaBlendFactor: VkBlendFactor;
    dstAlphaBlendFactor: VkBlendFactor;
    alphaBlendOp: VkBlendOp;
    colorWriteMask: VkColorComponentFlags;
  end;

  VkPipelineColorBlendStateCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineColorBlendStateCreateFlags;
    logicOpEnable: VkBool32;
    logicOp: VkLogicOp;
    attachmentCount: Cardinal;
    pAttachments: PVkPipelineColorBlendAttachmentState;
    blendConstants: array[0..4 - 1] of Single;
  end;

  VkPipelineDynamicStateCreateFlags = VkFlags;

  VkDynamicState = Integer;

  VkPipelineDynamicStateCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineDynamicStateCreateFlags;
    dynamicStateCount: Cardinal;
    pDynamicStates: PVkDynamicState;
  end;

  VkPipeline = UInt64;

  VkGraphicsPipelineCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineCreateFlags;
    stageCount: Cardinal;
    pStages: PVkPipelineShaderStageCreateInfo;
    pVertexInputState: PVkPipelineVertexInputStateCreateInfo;
    pInputAssemblyState: PVkPipelineInputAssemblyStateCreateInfo;
    pTessellationState: PVkPipelineTessellationStateCreateInfo;
    pViewportState: PVkPipelineViewportStateCreateInfo;
    pRasterizationState: PVkPipelineRasterizationStateCreateInfo;
    pMultisampleState: PVkPipelineMultisampleStateCreateInfo;
    pDepthStencilState: PVkPipelineDepthStencilStateCreateInfo;
    pColorBlendState: PVkPipelineColorBlendStateCreateInfo;
    pDynamicState: PVkPipelineDynamicStateCreateInfo;
    layout: VkPipelineLayout;
    renderPass: VkRenderPass;
    subpass: Cardinal;
    basePipelineHandle: VkPipeline;
    basePipelineIndex: Integer;
  end;

  VkCommandPoolCreateFlags = VkFlags;

  VkCommandPoolCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkCommandPoolCreateFlags;
    queueFamilyIndex: Cardinal;
  end;

  VkCommandPool = UInt64;

  VkCommandBufferLevel = Integer;

  VkCommandBufferAllocateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    commandPool: VkCommandPool;
    level: VkCommandBufferLevel;
    commandBufferCount: Cardinal;
  end;

  VkCommandBuffer = Pointer;

  VkCommandBufferResetFlags = VkFlags;

  VkCommandBufferUsageFlags = VkFlags;

  VkQueryControlFlags = VkFlags;

  VkQueryPipelineStatisticFlags = VkFlags;

  VkCommandBufferInheritanceInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    renderPass: VkRenderPass;
    subpass: Cardinal;
    framebuffer: VkFramebuffer;
    occlusionQueryEnable: VkBool32;
    queryFlags: VkQueryControlFlags;
    pipelineStatistics: VkQueryPipelineStatisticFlags;
  end;

  VkCommandBufferBeginInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkCommandBufferUsageFlags;
    pInheritanceInfo: PVkCommandBufferInheritanceInfo;
  end;

  VkMemoryBarrier = record
    sType: VkStructureType;
    pNext: Pointer;
    srcAccessMask: VkAccessFlags;
    dstAccessMask: VkAccessFlags;
  end;

  VkBufferMemoryBarrier = record
    sType: VkStructureType;
    pNext: Pointer;
    srcAccessMask: VkAccessFlags;
    dstAccessMask: VkAccessFlags;
    srcQueueFamilyIndex: Cardinal;
    dstQueueFamilyIndex: Cardinal;
    buffer: VkBuffer;
    offset: VkDeviceSize;
    size: VkDeviceSize;
  end;

  VkImageMemoryBarrier = record
    sType: VkStructureType;
    pNext: Pointer;
    srcAccessMask: VkAccessFlags;
    dstAccessMask: VkAccessFlags;
    oldLayout: VkImageLayout;
    newLayout: VkImageLayout;
    srcQueueFamilyIndex: Cardinal;
    dstQueueFamilyIndex: Cardinal;
    image: VkImage;
    subresourceRange: VkImageSubresourceRange;
  end;

  VkClearColorValue = record
    float32: array[0..3] of Single;
  end;

  VkClearValue = record
    color: VkClearColorValue;
  end;

  VkRenderPassBeginInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    renderPass: VkRenderPass;
    framebuffer: VkFramebuffer;
    renderArea: VkRect2D;
    clearValueCount: Cardinal;
    pClearValues: PVkClearValue;
  end;

  VkSubpassContents = Integer;

  VkFenceCreateFlags = VkFlags;

  VkFenceCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkFenceCreateFlags;
  end;

  VkFence = UInt64;

  VkSemaphore = UInt64;

  VkSubmitInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    waitSemaphoreCount: Cardinal;
    pWaitSemaphores: PVkSemaphore;
    pWaitDstStageMask: PVkPipelineStageFlags;
    commandBufferCount: Cardinal;
    pCommandBuffers: PVkCommandBuffer;
    signalSemaphoreCount: Cardinal;
    pSignalSemaphores: PVkSemaphore;
  end;

  VkMemoryGetFdInfoKHR = record
    sType: VkStructureType;
    pNext: Pointer;
    memory: VkDeviceMemory;
    handleType: VkExternalMemoryHandleTypeFlagBits;
  end;

  VkSemaphoreCreateFlags = VkFlags;

  VkSemaphoreCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkSemaphoreCreateFlags;
  end;

  VkExternalSemaphoreHandleTypeFlagBits = Integer;

  VkSemaphoreGetFdInfoKHR = record
    sType: VkStructureType;
    pNext: Pointer;
    semaphore: VkSemaphore;
    handleType: VkExternalSemaphoreHandleTypeFlagBits;
  end;

  VkPhysicalDeviceExternalSemaphoreInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    handleType: VkExternalSemaphoreHandleTypeFlagBits;
  end;

  VkExternalSemaphoreFeatureFlags = VkFlags;

  VkExternalSemaphoreProperties = record
    sType: VkStructureType;
    pNext: Pointer;
    exportFromImportedHandleTypes: VkExternalSemaphoreHandleTypeFlags;
    compatibleHandleTypes: VkExternalSemaphoreHandleTypeFlags;
    externalSemaphoreFeatures: VkExternalSemaphoreFeatureFlags;
  end;

  VkSemaphoreImportFlags = VkFlags;

  VkImportSemaphoreFdInfoKHR = record
    sType: VkStructureType;
    pNext: Pointer;
    semaphore: VkSemaphore;
    flags: VkSemaphoreImportFlags;
    handleType: VkExternalSemaphoreHandleTypeFlagBits;
    fd: Integer;
  end;

  VkAndroidHardwareBufferPropertiesANDROID = record
    sType: VkStructureType;
    pNext: Pointer;
    allocationSize: VkDeviceSize;
    memoryTypeBits: Cardinal;
  end;

  PFN_vkGetInstanceProcAddr = function(instance: VkInstance; pName: PAnsiChar): PFN_vkVoidFunction; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetDeviceProcAddr = function(device: VkDevice; pName: PAnsiChar): PFN_vkVoidFunction; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateInstance = function(pCreateInfo: PVkInstanceCreateInfo; pAllocator: Pointer; pInstance: PVkInstance): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyInstance = procedure(instance: VkInstance; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkEnumeratePhysicalDevices = function(instance: VkInstance; pPhysicalDeviceCount: PCardinal; pPhysicalDevices: PVkPhysicalDevice): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetPhysicalDeviceProperties2 = procedure(physicalDevice: VkPhysicalDevice; pProperties: PVkPhysicalDeviceProperties2); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetPhysicalDeviceQueueFamilyProperties = procedure(physicalDevice: VkPhysicalDevice; pQueueFamilyPropertyCount: PCardinal; pQueueFamilyProperties: PVkQueueFamilyProperties); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetPhysicalDeviceMemoryProperties = procedure(physicalDevice: VkPhysicalDevice; pMemoryProperties: PVkPhysicalDeviceMemoryProperties); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkEnumerateDeviceExtensionProperties = function(physicalDevice: VkPhysicalDevice; pLayerName: PAnsiChar; pPropertyCount: PCardinal; pProperties: PVkExtensionProperties): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetPhysicalDeviceImageFormatProperties2 = function(physicalDevice: VkPhysicalDevice; pImageFormatInfo: PVkPhysicalDeviceImageFormatInfo2; pImageFormatProperties: PVkImageFormatProperties2): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateDevice = function(physicalDevice: VkPhysicalDevice; pCreateInfo: PVkDeviceCreateInfo; pAllocator: Pointer; pDevice: PVkDevice): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyDevice = procedure(device: VkDevice; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetDeviceQueue = procedure(device: VkDevice; queueFamilyIndex: Cardinal; queueIndex: Cardinal; pQueue: PVkQueue); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateImage = function(device: VkDevice; pCreateInfo: PVkImageCreateInfo; pAllocator: Pointer; pImage: PVkImage): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyImage = procedure(device: VkDevice; image: VkImage; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetImageMemoryRequirements = procedure(device: VkDevice; image: VkImage; pMemoryRequirements: PVkMemoryRequirements); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetMemoryWin32HandlePropertiesKHR = function(device: VkDevice; handleType: VkExternalMemoryHandleTypeFlagBits; handle: NativeUInt; pMemoryWin32HandleProperties: PVkMemoryWin32HandlePropertiesKHR): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkAllocateMemory = function(device: VkDevice; pAllocateInfo: PVkMemoryAllocateInfo; pAllocator: Pointer; pMemory: PVkDeviceMemory): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkFreeMemory = procedure(device: VkDevice; memory: VkDeviceMemory; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkBindImageMemory = function(device: VkDevice; image: VkImage; memory: VkDeviceMemory; memoryOffset: VkDeviceSize): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateImageView = function(device: VkDevice; pCreateInfo: PVkImageViewCreateInfo; pAllocator: Pointer; pView: PVkImageView): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyImageView = procedure(device: VkDevice; imageView: VkImageView; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateRenderPass = function(device: VkDevice; pCreateInfo: PVkRenderPassCreateInfo; pAllocator: Pointer; pRenderPass: PVkRenderPass): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyRenderPass = procedure(device: VkDevice; renderPass: VkRenderPass; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateFramebuffer = function(device: VkDevice; pCreateInfo: PVkFramebufferCreateInfo; pAllocator: Pointer; pFramebuffer: PVkFramebuffer): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyFramebuffer = procedure(device: VkDevice; framebuffer: VkFramebuffer; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateShaderModule = function(device: VkDevice; pCreateInfo: PVkShaderModuleCreateInfo; pAllocator: Pointer; pShaderModule: PVkShaderModule): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyShaderModule = procedure(device: VkDevice; shaderModule: VkShaderModule; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreatePipelineLayout = function(device: VkDevice; pCreateInfo: PVkPipelineLayoutCreateInfo; pAllocator: Pointer; pPipelineLayout: PVkPipelineLayout): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyPipelineLayout = procedure(device: VkDevice; pipelineLayout: VkPipelineLayout; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateGraphicsPipelines = function(device: VkDevice; pipelineCache: VkPipelineCache; createInfoCount: Cardinal; pCreateInfos: PVkGraphicsPipelineCreateInfo; pAllocator: Pointer; pPipelines: PVkPipeline): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyPipeline = procedure(device: VkDevice; pipeline: VkPipeline; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateCommandPool = function(device: VkDevice; pCreateInfo: PVkCommandPoolCreateInfo; pAllocator: Pointer; pCommandPool: PVkCommandPool): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyCommandPool = procedure(device: VkDevice; commandPool: VkCommandPool; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkAllocateCommandBuffers = function(device: VkDevice; pAllocateInfo: PVkCommandBufferAllocateInfo; pCommandBuffers: PVkCommandBuffer): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkResetCommandBuffer = function(commandBuffer: VkCommandBuffer; flags: VkCommandBufferResetFlags): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkBeginCommandBuffer = function(commandBuffer: VkCommandBuffer; pBeginInfo: PVkCommandBufferBeginInfo): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkEndCommandBuffer = function(commandBuffer: VkCommandBuffer): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdPipelineBarrier = procedure(commandBuffer: VkCommandBuffer; srcStageMask: VkPipelineStageFlags; dstStageMask: VkPipelineStageFlags; dependencyFlags: VkDependencyFlags; memoryBarrierCount: Cardinal; pMemoryBarriers: PVkMemoryBarrier; bufferMemoryBarrierCount: Cardinal; pBufferMemoryBarriers: PVkBufferMemoryBarrier; imageMemoryBarrierCount: Cardinal; pImageMemoryBarriers: PVkImageMemoryBarrier); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdBeginRenderPass = procedure(commandBuffer: VkCommandBuffer; pRenderPassBegin: PVkRenderPassBeginInfo; contents: VkSubpassContents); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdEndRenderPass = procedure(commandBuffer: VkCommandBuffer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdBindPipeline = procedure(commandBuffer: VkCommandBuffer; pipelineBindPoint: VkPipelineBindPoint; pipeline: VkPipeline); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdPushConstants = procedure(commandBuffer: VkCommandBuffer; layout: VkPipelineLayout; stageFlags: VkShaderStageFlags; offset: Cardinal; size: Cardinal; pValues: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdSetViewport = procedure(commandBuffer: VkCommandBuffer; firstViewport: Cardinal; viewportCount: Cardinal; pViewports: PVkViewport); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdSetScissor = procedure(commandBuffer: VkCommandBuffer; firstScissor: Cardinal; scissorCount: Cardinal; pScissors: PVkRect2D); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdDraw = procedure(commandBuffer: VkCommandBuffer; vertexCount: Cardinal; instanceCount: Cardinal; firstVertex: Cardinal; firstInstance: Cardinal); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateFence = function(device: VkDevice; pCreateInfo: PVkFenceCreateInfo; pAllocator: Pointer; pFence: PVkFence): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyFence = procedure(device: VkDevice; fence: VkFence; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkResetFences = function(device: VkDevice; fenceCount: Cardinal; pFences: PVkFence): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkWaitForFences = function(device: VkDevice; fenceCount: Cardinal; pFences: PVkFence; waitAll: VkBool32; timeout: UInt64): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkQueueSubmit = function(queue: VkQueue; submitCount: Cardinal; pSubmits: PVkSubmitInfo; fence: VkFence): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDeviceWaitIdle = function(device: VkDevice): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetMemoryFdKHR = function(device: VkDevice; pGetFdInfo: PVkMemoryGetFdInfoKHR; pFd: PInteger): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateSemaphore = function(device: VkDevice; pCreateInfo: PVkSemaphoreCreateInfo; pAllocator: Pointer; pSemaphore: PVkSemaphore): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroySemaphore = procedure(device: VkDevice; semaphore: VkSemaphore; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetSemaphoreFdKHR = function(device: VkDevice; pGetFdInfo: PVkSemaphoreGetFdInfoKHR; pFd: PInteger): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetPhysicalDeviceExternalSemaphoreProperties = procedure(physicalDevice: VkPhysicalDevice; pExternalSemaphoreInfo: PVkPhysicalDeviceExternalSemaphoreInfo; pExternalSemaphoreProperties: PVkExternalSemaphoreProperties); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkImportSemaphoreFdKHR = function(device: VkDevice; pImportSemaphoreFdInfo: PVkImportSemaphoreFdInfoKHR): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetAndroidHardwareBufferPropertiesANDROID = function(device: VkDevice; buffer: Pointer; pProperties: PVkAndroidHardwareBufferPropertiesANDROID): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

implementation

end.

