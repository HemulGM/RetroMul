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

// Compute: buffers, descriptors, compute pipelines, timeline semaphores, timestamps.
const
  VK_NOT_READY = 1;
  VK_INCOMPLETE = 5;
  VK_ERROR_OUT_OF_HOST_MEMORY = -1;
  VK_ERROR_OUT_OF_DEVICE_MEMORY = -2;
  VK_ERROR_INITIALIZATION_FAILED = -3;
  VK_ERROR_DEVICE_LOST = -4;
  VK_ERROR_LAYER_NOT_PRESENT = -6;
  VK_ERROR_EXTENSION_NOT_PRESENT = -7;
  VK_ERROR_FEATURE_NOT_PRESENT = -8;
  VK_API_VERSION_1_2 = (1 shl 22) or (2 shl 12);
  VK_API_VERSION_1_3 = (1 shl 22) or (3 shl 12);
  VK_WHOLE_SIZE = UInt64($FFFFFFFFFFFFFFFF);
  VK_PHYSICAL_DEVICE_TYPE_OTHER = 0;
  VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU = 1;
  VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU = 2;
  VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU = 3;
  VK_PHYSICAL_DEVICE_TYPE_CPU = 4;
  VK_QUEUE_COMPUTE_BIT = $00000002;
  VK_QUEUE_TRANSFER_BIT = $00000004;
  VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT = $00000002;
  VK_MEMORY_PROPERTY_HOST_COHERENT_BIT = $00000004;
  VK_MEMORY_PROPERTY_HOST_CACHED_BIT = $00000008;
  VK_BUFFER_USAGE_TRANSFER_SRC_BIT = $00000001;
  VK_BUFFER_USAGE_TRANSFER_DST_BIT = $00000002;
  VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT = $00000010;
  VK_BUFFER_USAGE_STORAGE_BUFFER_BIT = $00000020;
  VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT = $00000100;
  VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER = 6;
  VK_DESCRIPTOR_TYPE_STORAGE_BUFFER = 7;
  VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT = $00000001;
  VK_SHADER_STAGE_COMPUTE_BIT = $00000020;
  VK_PIPELINE_BIND_POINT_COMPUTE = 1;
  VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT = $00000002;
  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT = $00000800;
  VK_PIPELINE_STAGE_TRANSFER_BIT = $00001000;
  VK_PIPELINE_STAGE_HOST_BIT = $00004000;
  VK_PIPELINE_STAGE_ALL_COMMANDS_BIT = $00010000;
  VK_ACCESS_INDIRECT_COMMAND_READ_BIT = $00000001;
  VK_ACCESS_UNIFORM_READ_BIT = $00000008;
  VK_ACCESS_SHADER_READ_BIT = $00000020;
  VK_ACCESS_SHADER_WRITE_BIT = $00000040;
  VK_ACCESS_TRANSFER_READ_BIT = $00000800;
  VK_ACCESS_TRANSFER_WRITE_BIT = $00001000;
  VK_ACCESS_HOST_READ_BIT = $00002000;
  VK_ACCESS_HOST_WRITE_BIT = $00004000;
  VK_ACCESS_MEMORY_READ_BIT = $00008000;
  VK_ACCESS_MEMORY_WRITE_BIT = $00010000;
  VK_FENCE_CREATE_SIGNALED_BIT = $00000001;
  VK_COMMAND_POOL_CREATE_TRANSIENT_BIT = $00000001;
  VK_SEMAPHORE_TYPE_BINARY = 0;
  VK_SEMAPHORE_TYPE_TIMELINE = 1;
  VK_QUERY_TYPE_TIMESTAMP = 2;
  VK_QUERY_RESULT_64_BIT = $00000001;
  VK_QUERY_RESULT_WAIT_BIT = $00000002;
  VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE = 6;
  VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO = 11;
  VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO = 12;
  VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO = 29;
  VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = 32;
  VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO = 33;
  VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO = 34;
  VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET = 35;
  VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER = 44;
  VK_STRUCTURE_TYPE_MEMORY_BARRIER = 46;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 = 1000059000;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_FLOAT16_INT8_FEATURES = 1000082000;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES = 1000083000;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_8BIT_STORAGE_FEATURES = 1000177000;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FLOAT_CONTROLS_PROPERTIES = 1000197000;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES = 1000207000;
  VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO = 1000207002;
  VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO = 1000207003;
  VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO = 1000207004;
  VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO = 1000207005;

type
  PVkBuffer = ^VkBuffer;

  PVkBufferCopy = ^VkBufferCopy;

  PVkBufferCreateInfo = ^VkBufferCreateInfo;

  PVkComputePipelineCreateInfo = ^VkComputePipelineCreateInfo;

  PVkDescriptorBufferInfo = ^VkDescriptorBufferInfo;

  PVkDescriptorPool = ^VkDescriptorPool;

  PVkDescriptorPoolCreateInfo = ^VkDescriptorPoolCreateInfo;

  PVkDescriptorPoolSize = ^VkDescriptorPoolSize;

  PVkDescriptorSet = ^VkDescriptorSet;

  PVkDescriptorSetAllocateInfo = ^VkDescriptorSetAllocateInfo;

  PVkDescriptorSetLayoutBinding = ^VkDescriptorSetLayoutBinding;

  PVkDescriptorSetLayoutCreateInfo = ^VkDescriptorSetLayoutCreateInfo;

  PVkMappedMemoryRange = ^VkMappedMemoryRange;

  PVkPhysicalDeviceFeatures2 = ^VkPhysicalDeviceFeatures2;

  PVkPhysicalDeviceProperties = ^VkPhysicalDeviceProperties;

  PVkQueryPool = ^VkQueryPool;

  PVkQueryPoolCreateInfo = ^VkQueryPoolCreateInfo;

  PVkSemaphoreSignalInfo = ^VkSemaphoreSignalInfo;

  PVkSemaphoreWaitInfo = ^VkSemaphoreWaitInfo;

  PVkSpecializationInfo = ^VkSpecializationInfo;

  PVkSpecializationMapEntry = ^VkSpecializationMapEntry;

  PVkWriteDescriptorSet = ^VkWriteDescriptorSet;

  VkBufferCreateFlags = VkFlags;

  VkBufferUsageFlags = VkFlags;

  VkBufferCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkBufferCreateFlags;
    size: VkDeviceSize;
    usage: VkBufferUsageFlags;
    sharingMode: VkSharingMode;
    queueFamilyIndexCount: Cardinal;
    pQueueFamilyIndices: PCardinal;
  end;

  VkBufferCopy = record
    srcOffset: VkDeviceSize;
    dstOffset: VkDeviceSize;
    size: VkDeviceSize;
  end;

  VkMemoryMapFlags = VkFlags;

  VkMappedMemoryRange = record
    sType: VkStructureType;
    pNext: Pointer;
    memory: VkDeviceMemory;
    offset: VkDeviceSize;
    size: VkDeviceSize;
  end;

  VkDescriptorType = Integer;

  VkDescriptorSetLayoutCreateFlags = VkFlags;

  VkDescriptorSetLayoutBinding = record
    binding: Cardinal;
    descriptorType: VkDescriptorType;
    descriptorCount: Cardinal;
    stageFlags: VkShaderStageFlags;
    pImmutableSamplers: Pointer;
  end;

  VkDescriptorSetLayoutCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkDescriptorSetLayoutCreateFlags;
    bindingCount: Cardinal;
    pBindings: PVkDescriptorSetLayoutBinding;
  end;

  VkDescriptorPool = UInt64;

  VkDescriptorSet = UInt64;

  VkDescriptorPoolCreateFlags = VkFlags;

  VkDescriptorPoolResetFlags = VkFlags;

  VkDescriptorPoolSize = record
    &type: VkDescriptorType;
    descriptorCount: Cardinal;
  end;

  VkDescriptorPoolCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkDescriptorPoolCreateFlags;
    maxSets: Cardinal;
    poolSizeCount: Cardinal;
    pPoolSizes: PVkDescriptorPoolSize;
  end;

  VkDescriptorSetAllocateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    descriptorPool: VkDescriptorPool;
    descriptorSetCount: Cardinal;
    pSetLayouts: PVkDescriptorSetLayout;
  end;

  VkDescriptorBufferInfo = record
    buffer: VkBuffer;
    offset: VkDeviceSize;
    range: VkDeviceSize;
  end;

  VkWriteDescriptorSet = record
    sType: VkStructureType;
    pNext: Pointer;
    dstSet: VkDescriptorSet;
    dstBinding: Cardinal;
    dstArrayElement: Cardinal;
    descriptorCount: Cardinal;
    descriptorType: VkDescriptorType;
    pImageInfo: Pointer;
    pBufferInfo: PVkDescriptorBufferInfo;
    pTexelBufferView: Pointer;
  end;

  VkSpecializationMapEntry = record
    constantID: Cardinal;
    offset: Cardinal;
    size: NativeUInt;
  end;

  VkSpecializationInfo = record
    mapEntryCount: Cardinal;
    pMapEntries: PVkSpecializationMapEntry;
    dataSize: NativeUInt;
    pData: Pointer;
  end;

  VkComputePipelineCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkPipelineCreateFlags;
    stage: VkPipelineShaderStageCreateInfo;
    layout: VkPipelineLayout;
    basePipelineHandle: VkPipeline;
    basePipelineIndex: Integer;
  end;

  VkPhysicalDeviceFeatures2 = record
    sType: VkStructureType;
    pNext: Pointer;
    features: VkPhysicalDeviceFeatures;
  end;

  VkPhysicalDevice16BitStorageFeatures = record
    sType: VkStructureType;
    pNext: Pointer;
    storageBuffer16BitAccess: VkBool32;
    uniformAndStorageBuffer16BitAccess: VkBool32;
    storagePushConstant16: VkBool32;
    storageInputOutput16: VkBool32;
  end;

  VkPhysicalDevice8BitStorageFeatures = record
    sType: VkStructureType;
    pNext: Pointer;
    storageBuffer8BitAccess: VkBool32;
    uniformAndStorageBuffer8BitAccess: VkBool32;
    storagePushConstant8: VkBool32;
  end;

  VkPhysicalDeviceShaderFloat16Int8Features = record
    sType: VkStructureType;
    pNext: Pointer;
    shaderFloat16: VkBool32;
    shaderInt8: VkBool32;
  end;

  VkPhysicalDeviceTimelineSemaphoreFeatures = record
    sType: VkStructureType;
    pNext: Pointer;
    timelineSemaphore: VkBool32;
  end;

  VkShaderFloatControlsIndependence = Integer;

  VkPhysicalDeviceFloatControlsProperties = record
    sType: VkStructureType;
    pNext: Pointer;
    denormBehaviorIndependence: VkShaderFloatControlsIndependence;
    roundingModeIndependence: VkShaderFloatControlsIndependence;
    shaderSignedZeroInfNanPreserveFloat16: VkBool32;
    shaderSignedZeroInfNanPreserveFloat32: VkBool32;
    shaderSignedZeroInfNanPreserveFloat64: VkBool32;
    shaderDenormPreserveFloat16: VkBool32;
    shaderDenormPreserveFloat32: VkBool32;
    shaderDenormPreserveFloat64: VkBool32;
    shaderDenormFlushToZeroFloat16: VkBool32;
    shaderDenormFlushToZeroFloat32: VkBool32;
    shaderDenormFlushToZeroFloat64: VkBool32;
    shaderRoundingModeRTEFloat16: VkBool32;
    shaderRoundingModeRTEFloat32: VkBool32;
    shaderRoundingModeRTEFloat64: VkBool32;
    shaderRoundingModeRTZFloat16: VkBool32;
    shaderRoundingModeRTZFloat32: VkBool32;
    shaderRoundingModeRTZFloat64: VkBool32;
  end;

  VkSemaphoreType = Integer;

  VkSemaphoreTypeCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    semaphoreType: VkSemaphoreType;
    initialValue: UInt64;
  end;

  VkTimelineSemaphoreSubmitInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    waitSemaphoreValueCount: Cardinal;
    pWaitSemaphoreValues: PUInt64;
    signalSemaphoreValueCount: Cardinal;
    pSignalSemaphoreValues: PUInt64;
  end;

  VkSemaphoreWaitFlags = VkFlags;

  VkSemaphoreWaitInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkSemaphoreWaitFlags;
    semaphoreCount: Cardinal;
    pSemaphores: PVkSemaphore;
    pValues: PUInt64;
  end;

  VkSemaphoreSignalInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    semaphore: VkSemaphore;
    value: UInt64;
  end;

  VkQueryPool = UInt64;

  VkQueryPoolCreateFlags = VkFlags;

  VkQueryType = Integer;

  VkQueryResultFlags = VkFlags;

  VkQueryPoolCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkQueryPoolCreateFlags;
    queryType: VkQueryType;
    queryCount: Cardinal;
    pipelineStatistics: VkQueryPipelineStatisticFlags;
  end;

  VkCommandPoolResetFlags = VkFlags;

  PFN_vkEnumerateInstanceVersion = function(pApiVersion: PCardinal): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetPhysicalDeviceProperties = procedure(physicalDevice: VkPhysicalDevice; pProperties: PVkPhysicalDeviceProperties); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetPhysicalDeviceFeatures2 = procedure(physicalDevice: VkPhysicalDevice; pFeatures: PVkPhysicalDeviceFeatures2); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateBuffer = function(device: VkDevice; pCreateInfo: PVkBufferCreateInfo; pAllocator: Pointer; pBuffer: PVkBuffer): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyBuffer = procedure(device: VkDevice; buffer: VkBuffer; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetBufferMemoryRequirements = procedure(device: VkDevice; buffer: VkBuffer; pMemoryRequirements: PVkMemoryRequirements); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkBindBufferMemory = function(device: VkDevice; buffer: VkBuffer; memory: VkDeviceMemory; memoryOffset: VkDeviceSize): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkMapMemory = function(device: VkDevice; memory: VkDeviceMemory; offset: VkDeviceSize; size: VkDeviceSize; flags: VkMemoryMapFlags; ppData: PPointer): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkUnmapMemory = procedure(device: VkDevice; memory: VkDeviceMemory); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkFlushMappedMemoryRanges = function(device: VkDevice; memoryRangeCount: Cardinal; pMemoryRanges: PVkMappedMemoryRange): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkInvalidateMappedMemoryRanges = function(device: VkDevice; memoryRangeCount: Cardinal; pMemoryRanges: PVkMappedMemoryRange): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateDescriptorSetLayout = function(device: VkDevice; pCreateInfo: PVkDescriptorSetLayoutCreateInfo; pAllocator: Pointer; pSetLayout: PVkDescriptorSetLayout): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyDescriptorSetLayout = procedure(device: VkDevice; descriptorSetLayout: VkDescriptorSetLayout; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateDescriptorPool = function(device: VkDevice; pCreateInfo: PVkDescriptorPoolCreateInfo; pAllocator: Pointer; pDescriptorPool: PVkDescriptorPool): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyDescriptorPool = procedure(device: VkDevice; descriptorPool: VkDescriptorPool; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkResetDescriptorPool = function(device: VkDevice; descriptorPool: VkDescriptorPool; flags: VkDescriptorPoolResetFlags): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkAllocateDescriptorSets = function(device: VkDevice; pAllocateInfo: PVkDescriptorSetAllocateInfo; pDescriptorSets: PVkDescriptorSet): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkFreeDescriptorSets = function(device: VkDevice; descriptorPool: VkDescriptorPool; descriptorSetCount: Cardinal; pDescriptorSets: PVkDescriptorSet): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkUpdateDescriptorSets = procedure(device: VkDevice; descriptorWriteCount: Cardinal; pDescriptorWrites: PVkWriteDescriptorSet; descriptorCopyCount: Cardinal; pDescriptorCopies: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateComputePipelines = function(device: VkDevice; pipelineCache: VkPipelineCache; createInfoCount: Cardinal; pCreateInfos: PVkComputePipelineCreateInfo; pAllocator: Pointer; pPipelines: PVkPipeline): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdBindDescriptorSets = procedure(commandBuffer: VkCommandBuffer; pipelineBindPoint: VkPipelineBindPoint; layout: VkPipelineLayout; firstSet: Cardinal; descriptorSetCount: Cardinal; pDescriptorSets: PVkDescriptorSet; dynamicOffsetCount: Cardinal; pDynamicOffsets: PCardinal); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdDispatch = procedure(commandBuffer: VkCommandBuffer; groupCountX: Cardinal; groupCountY: Cardinal; groupCountZ: Cardinal); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdDispatchIndirect = procedure(commandBuffer: VkCommandBuffer; buffer: VkBuffer; offset: VkDeviceSize); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdCopyBuffer = procedure(commandBuffer: VkCommandBuffer; srcBuffer: VkBuffer; dstBuffer: VkBuffer; regionCount: Cardinal; pRegions: PVkBufferCopy); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdFillBuffer = procedure(commandBuffer: VkCommandBuffer; dstBuffer: VkBuffer; dstOffset: VkDeviceSize; size: VkDeviceSize; data: Cardinal); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdUpdateBuffer = procedure(commandBuffer: VkCommandBuffer; dstBuffer: VkBuffer; dstOffset: VkDeviceSize; dataSize: VkDeviceSize; pData: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkFreeCommandBuffers = procedure(device: VkDevice; commandPool: VkCommandPool; commandBufferCount: Cardinal; pCommandBuffers: PVkCommandBuffer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkResetCommandPool = function(device: VkDevice; commandPool: VkCommandPool; flags: VkCommandPoolResetFlags): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetFenceStatus = function(device: VkDevice; fence: VkFence): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkQueueWaitIdle = function(queue: VkQueue): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkWaitSemaphores = function(device: VkDevice; pWaitInfo: PVkSemaphoreWaitInfo; timeout: UInt64): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkSignalSemaphore = function(device: VkDevice; pSignalInfo: PVkSemaphoreSignalInfo): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetSemaphoreCounterValue = function(device: VkDevice; semaphore: VkSemaphore; pValue: PUInt64): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCreateQueryPool = function(device: VkDevice; pCreateInfo: PVkQueryPoolCreateInfo; pAllocator: Pointer; pQueryPool: PVkQueryPool): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkDestroyQueryPool = procedure(device: VkDevice; queryPool: VkQueryPool; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdResetQueryPool = procedure(commandBuffer: VkCommandBuffer; queryPool: VkQueryPool; firstQuery: Cardinal; queryCount: Cardinal); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkCmdWriteTimestamp = procedure(commandBuffer: VkCommandBuffer; pipelineStage: VkPipelineStageFlags; queryPool: VkQueryPool; query: Cardinal); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

  PFN_vkGetQueryPoolResults = function(device: VkDevice; queryPool: VkQueryPool; firstQuery: Cardinal; queryCount: Cardinal; dataSize: NativeUInt; pData: Pointer; stride: VkDeviceSize; flags: VkQueryResultFlags): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

// Rendering with graphics pipelines into images: samplers, depth/stencil,
// image transfers and the fixed-function state enums.
const
  VK_FORMAT_R8_UINT = 13;
  VK_FORMAT_R8G8B8A8_UINT = 41;
  VK_FORMAT_R32_UINT = 98;
  VK_FORMAT_R32_SFLOAT = 100;
  VK_FORMAT_R32G32_SFLOAT = 103;
  VK_FORMAT_R32G32B32_SFLOAT = 106;
  VK_FORMAT_R32G32B32A32_SFLOAT = 109;
  VK_FORMAT_D32_SFLOAT = 126;
  VK_FORMAT_D24_UNORM_S8_UINT = 129;
  VK_FORMAT_D32_SFLOAT_S8_UINT = 130;
  VK_IMAGE_USAGE_TRANSFER_DST_BIT = $00000002;
  VK_IMAGE_USAGE_STORAGE_BIT = $00000008;
  VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT = $00000020;
  VK_IMAGE_ASPECT_DEPTH_BIT = $00000002;
  VK_IMAGE_ASPECT_STENCIL_BIT = $00000004;
  VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL = 3;
  VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL = 5;
  VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL = 6;
  VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL = 7;
  VK_REMAINING_MIP_LEVELS = $FFFFFFFF;
  VK_ATTACHMENT_LOAD_OP_LOAD = 0;
  VK_PIPELINE_STAGE_VERTEX_INPUT_BIT = $00000004;
  VK_PIPELINE_STAGE_VERTEX_SHADER_BIT = $00000008;
  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT = $00000080;
  VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT = $00000100;
  VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT = $00000200;
  VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT = $00000004;
  VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT = $00000200;
  VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT = $00000400;
  VK_DEPENDENCY_BY_REGION_BIT = $00000001;
  VK_BUFFER_USAGE_VERTEX_BUFFER_BIT = $00000080;
  VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT = $00000200;
  VK_FORMAT_FEATURE_BLIT_SRC_BIT = $00000400;
  VK_FORMAT_FEATURE_BLIT_DST_BIT = $00000800;
  VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO = 25;
  VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO = 31;
  VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER = 1;
  VK_PRIMITIVE_TOPOLOGY_POINT_LIST = 0;
  VK_PRIMITIVE_TOPOLOGY_LINE_LIST = 1;
  VK_VERTEX_INPUT_RATE_VERTEX = 0;
  VK_DYNAMIC_STATE_BLEND_CONSTANTS = 4;
  VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK = 6;
  VK_DYNAMIC_STATE_STENCIL_WRITE_MASK = 7;
  VK_DYNAMIC_STATE_STENCIL_REFERENCE = 8;
  VK_STENCIL_FACE_FRONT_AND_BACK = 3;
  VK_BLEND_FACTOR_ZERO = 0;
  VK_BLEND_FACTOR_ONE = 1;
  VK_BLEND_FACTOR_SRC_COLOR = 2;
  VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR = 3;
  VK_BLEND_FACTOR_DST_COLOR = 4;
  VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR = 5;
  VK_BLEND_FACTOR_SRC_ALPHA = 6;
  VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA = 7;
  VK_BLEND_FACTOR_DST_ALPHA = 8;
  VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA = 9;
  VK_BLEND_FACTOR_CONSTANT_COLOR = 10;
  VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR = 11;
  VK_BLEND_FACTOR_SRC1_COLOR = 15;
  VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR = 16;
  VK_BLEND_OP_ADD = 0;
  VK_BLEND_OP_SUBTRACT = 1;
  VK_BLEND_OP_REVERSE_SUBTRACT = 2;
  VK_BLEND_OP_MIN = 3;
  VK_BLEND_OP_MAX = 4;
  VK_COMPARE_OP_NEVER = 0;
  VK_COMPARE_OP_LESS = 1;
  VK_COMPARE_OP_EQUAL = 2;
  VK_COMPARE_OP_LESS_OR_EQUAL = 3;
  VK_COMPARE_OP_GREATER = 4;
  VK_COMPARE_OP_NOT_EQUAL = 5;
  VK_COMPARE_OP_GREATER_OR_EQUAL = 6;
  VK_COMPARE_OP_ALWAYS = 7;
  VK_STENCIL_OP_KEEP = 0;
  VK_STENCIL_OP_ZERO = 1;
  VK_STENCIL_OP_REPLACE = 2;
  VK_STENCIL_OP_INCREMENT_AND_CLAMP = 3;
  VK_STENCIL_OP_DECREMENT_AND_CLAMP = 4;
  VK_STENCIL_OP_INVERT = 5;
  VK_LOGIC_OP_COPY = 3;
  VK_FILTER_NEAREST = 0;
  VK_FILTER_LINEAR = 1;
  VK_SAMPLER_MIPMAP_MODE_NEAREST = 0;
  VK_SAMPLER_MIPMAP_MODE_LINEAR = 1;
  VK_SAMPLER_ADDRESS_MODE_REPEAT = 0;
  VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE = 2;
  VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK = 0;
  VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT = $00000002;
  VK_DESCRIPTOR_TYPE_STORAGE_IMAGE = 3;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT = 1000251000;
  VK_EXT_FRAGMENT_SHADER_INTERLOCK_EXTENSION_NAME = 'VK_EXT_fragment_shader_interlock';

type
  VkFilter = Integer;
  VkSamplerMipmapMode = Integer;
  VkSamplerAddressMode = Integer;
  VkBorderColor = Integer;
  VkSampler = UInt64;
  PVkSampler = ^VkSampler;
  PVkDeviceSize = ^VkDeviceSize;

  VkSamplerCreateInfo = record
    sType: VkStructureType;
    pNext: Pointer;
    flags: VkFlags;
    magFilter: VkFilter;
    minFilter: VkFilter;
    mipmapMode: VkSamplerMipmapMode;
    addressModeU: VkSamplerAddressMode;
    addressModeV: VkSamplerAddressMode;
    addressModeW: VkSamplerAddressMode;
    mipLodBias: Single;
    anisotropyEnable: VkBool32;
    maxAnisotropy: Single;
    compareEnable: VkBool32;
    compareOp: VkCompareOp;
    minLod: Single;
    maxLod: Single;
    borderColor: VkBorderColor;
    unnormalizedCoordinates: VkBool32;
  end;
  PVkSamplerCreateInfo = ^VkSamplerCreateInfo;

  VkDescriptorImageInfo = record
    sampler: VkSampler;
    imageView: VkImageView;
    imageLayout: VkImageLayout;
  end;

  VkImageSubresourceLayers = record
    aspectMask: VkImageAspectFlags;
    mipLevel: Cardinal;
    baseArrayLayer: Cardinal;
    layerCount: Cardinal;
  end;

  VkOffset3D = record
    x: Integer;
    y: Integer;
    z: Integer;
  end;

  VkBufferImageCopy = record
    bufferOffset: VkDeviceSize;
    bufferRowLength: Cardinal;
    bufferImageHeight: Cardinal;
    imageSubresource: VkImageSubresourceLayers;
    imageOffset: VkOffset3D;
    imageExtent: VkExtent3D;
  end;
  PVkBufferImageCopy = ^VkBufferImageCopy;

  VkImageBlit = record
    srcSubresource: VkImageSubresourceLayers;
    srcOffsets: array[0..1] of VkOffset3D;
    dstSubresource: VkImageSubresourceLayers;
    dstOffsets: array[0..1] of VkOffset3D;
  end;
  PVkImageBlit = ^VkImageBlit;

  VkImageCopy = record
    srcSubresource: VkImageSubresourceLayers;
    srcOffset: VkOffset3D;
    dstSubresource: VkImageSubresourceLayers;
    dstOffset: VkOffset3D;
    extent: VkExtent3D;
  end;
  PVkImageCopy = ^VkImageCopy;

  // clearValue holds a VkClearDepthStencilValue (depth, stencil) in its first
  // two words for depth/stencil aspects.
  VkClearAttachment = record
    aspectMask: VkImageAspectFlags;
    colorAttachment: Cardinal;
    clearValue: VkClearValue;
  end;
  PVkClearAttachment = ^VkClearAttachment;

  VkClearRect = record
    rect: VkRect2D;
    baseArrayLayer: Cardinal;
    layerCount: Cardinal;
  end;
  PVkClearRect = ^VkClearRect;

  VkFormatProperties = record
    linearTilingFeatures: VkFormatFeatureFlags;
    optimalTilingFeatures: VkFormatFeatureFlags;
    bufferFeatures: VkFormatFeatureFlags;
  end;
  PVkFormatProperties = ^VkFormatProperties;

  VkPhysicalDeviceFragmentShaderInterlockFeaturesEXT = record
    sType: VkStructureType;
    pNext: Pointer;
    fragmentShaderSampleInterlock: VkBool32;
    fragmentShaderPixelInterlock: VkBool32;
    fragmentShaderShadingRateInterlock: VkBool32;
  end;

  PFN_vkCreateSampler = function(device: VkDevice; pCreateInfo: PVkSamplerCreateInfo; pAllocator: Pointer; pSampler: PVkSampler): VkResult; {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkDestroySampler = procedure(device: VkDevice; sampler: VkSampler; pAllocator: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkCmdBindVertexBuffers = procedure(commandBuffer: VkCommandBuffer; firstBinding: Cardinal; bindingCount: Cardinal; pBuffers: PVkBuffer; pOffsets: PVkDeviceSize); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkCmdCopyBufferToImage = procedure(commandBuffer: VkCommandBuffer; srcBuffer: VkBuffer; dstImage: VkImage; dstImageLayout: VkImageLayout; regionCount: Cardinal; pRegions: PVkBufferImageCopy); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkCmdCopyImageToBuffer = procedure(commandBuffer: VkCommandBuffer; srcImage: VkImage; srcImageLayout: VkImageLayout; dstBuffer: VkBuffer; regionCount: Cardinal; pRegions: PVkBufferImageCopy); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkCmdBlitImage = procedure(commandBuffer: VkCommandBuffer; srcImage: VkImage; srcImageLayout: VkImageLayout; dstImage: VkImage; dstImageLayout: VkImageLayout; regionCount: Cardinal; pRegions: PVkImageBlit; filter: VkFilter); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkCmdCopyImage = procedure(commandBuffer: VkCommandBuffer; srcImage: VkImage; srcImageLayout: VkImageLayout; dstImage: VkImage; dstImageLayout: VkImageLayout; regionCount: Cardinal; pRegions: PVkImageCopy); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkCmdSetBlendConstants = procedure(commandBuffer: VkCommandBuffer; blendConstants: PSingle); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkCmdSetStencilReference = procedure(commandBuffer: VkCommandBuffer; faceMask: VkFlags; reference: Cardinal); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkCmdSetStencilCompareMask = procedure(commandBuffer: VkCommandBuffer; faceMask: VkFlags; compareMask: Cardinal); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkCmdSetStencilWriteMask = procedure(commandBuffer: VkCommandBuffer; faceMask: VkFlags; writeMask: Cardinal); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkCmdClearAttachments = procedure(commandBuffer: VkCommandBuffer; attachmentCount: Cardinal; pAttachments: PVkClearAttachment; rectCount: Cardinal; pRects: PVkClearRect); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};
  PFN_vkGetPhysicalDeviceFormatProperties = procedure(physicalDevice: VkPhysicalDevice; format: VkFormat; pFormatProperties: PVkFormatProperties); {$IFDEF MSWINDOWS}stdcall{$ELSE} cdecl{$ENDIF};

implementation

end.

