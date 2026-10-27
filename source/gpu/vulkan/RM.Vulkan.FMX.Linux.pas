unit RM.Vulkan.FMX.Linux;

// FMXLinux GPU canvas bridge. Export Vulkan RGBA8 memory and binary semaphores
// as opaque FDs, import them into the same GPU's OpenGL share group, then blit
// into the public TBitmapCtx render target. UI thread only; no pixel readback.
interface

uses
  System.SysUtils, System.Messaging, FMX.Graphics, FMX.Types3D,
  RM.Vulkan.Bindings, RM.Vulkan.Device, RM.Vulkan.OpenGL.Linux;

type
  TVulkanFMXTexture = class
  private
    FBitmap: TBitmap; // Borrowed.
    FBitmapTexture: TTexture; // Borrowed from TBitmapCtx.
    FDevice: TVulkanDevice;
    FGL: TVulkanOpenGL;
    FSharedContext: Pointer;
    FBitmapHandle: NativeUInt;
    FImage: VkImage;
    FMemory: VkDeviceMemory;
    FView: VkImageView;
    FReady, FDone: VkSemaphore;
    FGLMemory, FGLTexture, FGLReady, FGLDone: Cardinal;
    FReadFBO, FDrawFBO: Cardinal;
    FWidth, FHeight: Integer;
    FFormat: VkFormat;
    FInitialQueueFamily: Cardinal;
    FExternalQueueFamily: Cardinal;
    FValid, FSubmitted: Boolean;
    FContextLostSubscription: Integer;
    procedure ContextLost(const Sender: TObject; const Message: TMessage);
    procedure MakeCurrent;
    procedure RestoreContext;
    procedure CreateImage;
    procedure CreateSemaphores;
    procedure CreateGLTexture;
    procedure CopyToBitmap;
    procedure ImportSemaphore(Semaphore: VkSemaphore; var GLSemaphore: Cardinal);
  public
    constructor Create(Bitmap: TBitmap; Width, Height: Integer);
    destructor Destroy; override;
    procedure CheckContext;
    procedure SubmitAndCopy(CommandBuffer: VkCommandBuffer; Fence: VkFence);
    property Device: TVulkanDevice read FDevice;
    property Image: VkImage read FImage;
    property View: VkImageView read FView;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Format: VkFormat read FFormat;
    property InitialQueueFamily: Cardinal read FInitialQueueFamily;
    property ExternalQueueFamily: Cardinal read FExternalQueueFamily;
  end;

implementation

uses
  Posix.Unistd, FMX.Canvas.GPU, FMX.Context.Linux, FMUX.Api, RM.Vulkan.Loader;

procedure TVulkanFMXTexture.MakeCurrent;
begin
  if FSharedContext = nil then
    raise EVulkanError.Create('No FMXLinux OpenGL share context.');
  FmuxMakeCurrentContext(FSharedContext);
end;

procedure TVulkanFMXTexture.RestoreContext;
begin
  // Return to the context FMX currently considers active. FBOs belong to the
  // share context used by this bridge; textures and external objects are shared.
  TCustomContextOpenGL.Valid;
end;

constructor TVulkanFMXTexture.Create(Bitmap: TBitmap; Width, Height: Integer);
var
  DeviceUUID, DriverUUID: TVulkanUUID;
  DeviceCount: Integer;
  BitmapObject: TObject;
begin
  inherited Create;
  if (Bitmap = nil) or (Width <= 0) or (Height <= 0) then
    raise EArgumentException.Create('A bitmap and positive texture dimensions are required.');
  if not TCanvasManager.DefaultCanvas.InheritsFrom(TCustomCanvasGpu) then
    raise EVulkanError.Create('Vulkan sharing requires the FMXLinux GPU canvas. The Cairo bitmap canvas has no GPU texture.');
  if not TContextManager.DefaultContextClass.InheritsFrom(TCustomContextOpenGL) then
    raise EVulkanError.Create('Vulkan sharing requires the FMXLinux OpenGL context.');
  FBitmap := Bitmap;
  FWidth := Width;
  FHeight := Height;
  FFormat := VK_FORMAT_R8G8B8A8_UNORM;
  // Newly created Vulkan images have no external owner before their first use.
  FInitialQueueFamily := VK_QUEUE_FAMILY_IGNORED;
  FExternalQueueFamily := VK_QUEUE_FAMILY_EXTERNAL;
  FSharedContext := TCustomContextOpenGL.SharedContext;
  MakeCurrent;
  try
    FGL := TVulkanOpenGL.Create;
    DeviceCount := 0;
    FGL.GetIntegerv(GL_NUM_DEVICE_UUIDS_EXT, @DeviceCount);
    FGL.Check('Query OpenGL device count');
    if DeviceCount <> 1 then
      raise EVulkanError.CreateFmt('Expected one OpenGL device UUID; got %d. Multi-device share groups are not supported.', [DeviceCount]);
    FGL.GetUnsignedByteiv(GL_DEVICE_UUID_EXT, 0, @DeviceUUID[0]);
    FGL.GetUnsignedBytev(GL_DRIVER_UUID_EXT, @DriverUUID[0]);
    FGL.Check('Query OpenGL device/driver UUID');
    FDevice := TVulkanDevice.Create(DeviceUUID, DriverUUID);
    CreateImage;
    CreateSemaphores;
    FBitmap.SetSize(Width, Height);
    FBitmapHandle := FBitmap.Handle;
    BitmapObject := TObject(FBitmapHandle);
    if not (BitmapObject is TBitmapCtx) then
      raise EVulkanError.Create('The FMXLinux bitmap is not backed by TBitmapCtx.');
    FBitmapTexture := TBitmapCtx(BitmapObject).RenderTarget;
    FBitmapTexture.Initialize;
    // Texture.Initialize may switch to FMX's current form context.
    MakeCurrent;
    CreateGLTexture;
    FValid := True;
    FContextLostSubscription := TMessageManager.DefaultManager.SubscribeToMessage(TContextLostMessage, ContextLost);
  finally
    RestoreContext;
  end;
end;

procedure TVulkanFMXTexture.CreateImage;
var
  ExternalInfo: VkPhysicalDeviceExternalImageFormatInfo;
  FormatInfo: VkPhysicalDeviceImageFormatInfo2;
  ExternalProperties: VkExternalImageFormatProperties;
  FormatProperties: VkImageFormatProperties2;
  ExternalImage: VkExternalMemoryImageCreateInfo;
  ImageInfo: VkImageCreateInfo;
  Requirements: VkMemoryRequirements;
  ExportInfo: VkExportMemoryAllocateInfo;
  Dedicated: VkMemoryDedicatedAllocateInfo;
  AllocateInfo: VkMemoryAllocateInfo;
  ViewInfo: VkImageViewCreateInfo;
begin
  ExternalInfo := Default(VkPhysicalDeviceExternalImageFormatInfo);
  ExternalInfo.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO;
  ExternalInfo.handleType := VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
  FormatInfo := Default(VkPhysicalDeviceImageFormatInfo2);
  FormatInfo.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2;
  FormatInfo.pNext := @ExternalInfo;
  FormatInfo.format := FFormat;
  FormatInfo.&type := VK_IMAGE_TYPE_2D;
  FormatInfo.tiling := VK_IMAGE_TILING_OPTIMAL;
  FormatInfo.usage := VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT or VK_IMAGE_USAGE_SAMPLED_BIT or VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
  ExternalProperties := Default(VkExternalImageFormatProperties);
  ExternalProperties.sType := VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES;
  FormatProperties := Default(VkImageFormatProperties2);
  FormatProperties.sType := VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
  FormatProperties.pNext := @ExternalProperties;
  CheckVulkan(FDevice.API.vkGetPhysicalDeviceImageFormatProperties2(FDevice.PhysicalDevice,
      @FormatInfo, @FormatProperties), 'Check RGBA8 opaque FD image export');
  if ExternalProperties.externalMemoryProperties.externalMemoryFeatures and VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT = 0 then
    raise EVulkanError.Create('The Vulkan driver cannot export an RGBA8 image as an opaque FD.');
  if (Cardinal(FWidth) > FormatProperties.imageFormatProperties.maxExtent.width) or
    (Cardinal(FHeight) > FormatProperties.imageFormatProperties.maxExtent.height) then
    raise EVulkanError.Create('The shared texture exceeds the Vulkan image size limit.');
  ExternalImage := Default(VkExternalMemoryImageCreateInfo);
  ExternalImage.sType := VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
  ExternalImage.handleTypes := ExternalInfo.handleType;
  ImageInfo := Default(VkImageCreateInfo);
  ImageInfo.sType := VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
  ImageInfo.pNext := @ExternalImage;
  ImageInfo.imageType := VK_IMAGE_TYPE_2D;
  ImageInfo.format := FFormat;
  ImageInfo.extent.width := FWidth;
  ImageInfo.extent.height := FHeight;
  ImageInfo.extent.depth := 1;
  ImageInfo.mipLevels := 1;
  ImageInfo.arrayLayers := 1;
  ImageInfo.samples := VK_SAMPLE_COUNT_1_BIT;
  ImageInfo.tiling := VK_IMAGE_TILING_OPTIMAL;
  ImageInfo.usage := FormatInfo.usage;
  ImageInfo.sharingMode := VK_SHARING_MODE_EXCLUSIVE;
  ImageInfo.initialLayout := VK_IMAGE_LAYOUT_UNDEFINED;
  CheckVulkan(FDevice.API.vkCreateImage(FDevice.Handle, @ImageInfo, nil, @FImage), 'vkCreateImage (exportable RGBA8)');
  FDevice.API.vkGetImageMemoryRequirements(FDevice.Handle, FImage, @Requirements);
  Dedicated := Default(VkMemoryDedicatedAllocateInfo);
  Dedicated.sType := VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
  Dedicated.image := FImage;
  ExportInfo := Default(VkExportMemoryAllocateInfo);
  ExportInfo.sType := VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO;
  ExportInfo.pNext := @Dedicated;
  ExportInfo.handleTypes := ExternalInfo.handleType;
  AllocateInfo := Default(VkMemoryAllocateInfo);
  AllocateInfo.sType := VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  AllocateInfo.pNext := @ExportInfo;
  AllocateInfo.allocationSize := Requirements.size;
  AllocateInfo.memoryTypeIndex := FDevice.MemoryType(Requirements.memoryTypeBits);
  CheckVulkan(FDevice.API.vkAllocateMemory(FDevice.Handle, @AllocateInfo, nil, @FMemory), 'vkAllocateMemory (FD export)');
  CheckVulkan(FDevice.API.vkBindImageMemory(FDevice.Handle, FImage, FMemory, 0), 'vkBindImageMemory');
  ViewInfo := Default(VkImageViewCreateInfo);
  ViewInfo.sType := VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
  ViewInfo.image := FImage;
  ViewInfo.viewType := VK_IMAGE_VIEW_TYPE_2D;
  ViewInfo.format := FFormat;
  ViewInfo.subresourceRange.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  ViewInfo.subresourceRange.levelCount := 1;
  ViewInfo.subresourceRange.layerCount := 1;
  CheckVulkan(FDevice.API.vkCreateImageView(FDevice.Handle, @ViewInfo, nil, @FView), 'vkCreateImageView');
end;

procedure TVulkanFMXTexture.ImportSemaphore(Semaphore: VkSemaphore; var GLSemaphore: Cardinal);
var
  Info: VkSemaphoreGetFdInfoKHR;
  FD: Integer;
begin
  Info := Default(VkSemaphoreGetFdInfoKHR);
  Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
  Info.semaphore := Semaphore;
  Info.handleType := VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
  FD := -1;
  CheckVulkan(FDevice.API.vkGetSemaphoreFdKHR(FDevice.Handle, @Info, @FD), 'vkGetSemaphoreFdKHR');
  try
    FGL.GenSemaphores(1, @GLSemaphore);
    FGL.Check('Create OpenGL external semaphore');
    FGL.ImportSemaphoreFd(GLSemaphore, GL_HANDLE_TYPE_OPAQUE_FD_EXT, FD);
    FGL.Check('Import OpenGL semaphore FD');
    FD := -1; // A successful import transfers ownership to OpenGL.
  finally
    if FD >= 0 then
      __close(FD);
  end;
end;

procedure TVulkanFMXTexture.CreateSemaphores;
var
  ExternalInfo: VkPhysicalDeviceExternalSemaphoreInfo;
  Properties: VkExternalSemaphoreProperties;
  ExportInfo: VkExportSemaphoreCreateInfo;
  Info: VkSemaphoreCreateInfo;
begin
  ExternalInfo := Default(VkPhysicalDeviceExternalSemaphoreInfo);
  ExternalInfo.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO;
  ExternalInfo.handleType := VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
  Properties := Default(VkExternalSemaphoreProperties);
  Properties.sType := VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES;
  FDevice.API.vkGetPhysicalDeviceExternalSemaphoreProperties(FDevice.PhysicalDevice, @ExternalInfo, @Properties);
  if Properties.externalSemaphoreFeatures and VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT = 0 then
    raise EVulkanError.Create('The Vulkan driver cannot export binary semaphores as opaque FDs.');
  ExportInfo := Default(VkExportSemaphoreCreateInfo);
  ExportInfo.sType := VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO;
  ExportInfo.handleTypes := ExternalInfo.handleType;
  Info := Default(VkSemaphoreCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
  Info.pNext := @ExportInfo;
  CheckVulkan(FDevice.API.vkCreateSemaphore(FDevice.Handle, @Info, nil, @FReady), 'Create Vulkan ready semaphore');
  CheckVulkan(FDevice.API.vkCreateSemaphore(FDevice.Handle, @Info, nil, @FDone), 'Create Vulkan done semaphore');
  ImportSemaphore(FReady, FGLReady);
  ImportSemaphore(FDone, FGLDone);
end;

procedure TVulkanFMXTexture.CreateGLTexture;
var
  Requirements: VkMemoryRequirements;
  Info: VkMemoryGetFdInfoKHR;
  FD, OldTexture, OldRead, OldDraw, Dedicated: Integer;
begin
  FDevice.API.vkGetImageMemoryRequirements(FDevice.Handle, FImage, @Requirements);
  Info := Default(VkMemoryGetFdInfoKHR);
  Info.sType := VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR;
  Info.memory := FMemory;
  Info.handleType := VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
  FD := -1;
  CheckVulkan(FDevice.API.vkGetMemoryFdKHR(FDevice.Handle, @Info, @FD), 'vkGetMemoryFdKHR');
  try
    FGL.CreateMemoryObjects(1, @FGLMemory);
    FGL.Check('Create OpenGL memory object');
    Dedicated := 1;
    FGL.MemoryObjectParameteriv(FGLMemory, GL_DEDICATED_MEMORY_OBJECT_EXT, @Dedicated);
    FGL.Check('Set dedicated OpenGL memory');
    FGL.ImportMemoryFd(FGLMemory, Requirements.size, GL_HANDLE_TYPE_OPAQUE_FD_EXT, FD);
    FGL.Check('Import OpenGL memory FD');
    FD := -1;
  finally
    if FD >= 0 then
      __close(FD);
  end;
  FGL.GetIntegerv(GL_TEXTURE_BINDING_2D, @OldTexture);
  FGL.GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, @OldRead);
  FGL.GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, @OldDraw);
  try
    FGL.GenTextures(1, @FGLTexture);
    FGL.BindTexture(GL_TEXTURE_2D, FGLTexture);
    FGL.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    FGL.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    FGL.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_TILING_EXT, GL_OPTIMAL_TILING_EXT);
    FGL.TexStorageMem2D(GL_TEXTURE_2D, 1, GL_RGBA8, FWidth, FHeight, FGLMemory, 0);
    FGL.Check('Create OpenGL texture from Vulkan allocation');
    FGL.GenFramebuffers(1, @FReadFBO);
    FGL.GenFramebuffers(1, @FDrawFBO);
    FGL.BindFramebuffer(GL_READ_FRAMEBUFFER, FReadFBO);
    FGL.FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, FGLTexture, 0);
    if FGL.CheckFramebufferStatus(GL_READ_FRAMEBUFFER) <> GL_FRAMEBUFFER_COMPLETE then
      raise EVulkanError.Create('The imported Vulkan texture framebuffer is incomplete.');
    FGL.BindFramebuffer(GL_DRAW_FRAMEBUFFER, FDrawFBO);
    FGL.FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, Cardinal(FBitmapTexture.Handle), 0);
    if FGL.CheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) <> GL_FRAMEBUFFER_COMPLETE then
      raise EVulkanError.Create('The FMXLinux bitmap framebuffer is incomplete.');
    FGL.Check('Create OpenGL transfer framebuffers');
  finally
    FGL.BindTexture(GL_TEXTURE_2D, OldTexture);
    FGL.BindFramebuffer(GL_READ_FRAMEBUFFER, OldRead);
    FGL.BindFramebuffer(GL_DRAW_FRAMEBUFFER, OldDraw);
  end;
end;

procedure TVulkanFMXTexture.CheckContext;
begin
  if not FValid then
    raise EVulkanError.Create('The FMXLinux OpenGL context was lost. Recreate the Vulkan bitmap bridge.');
  if (FBitmap.Width <> FWidth) or (FBitmap.Height <> FHeight) or
    (FBitmap.Handle <> FBitmapHandle) or
    (TCustomContextOpenGL.SharedContext <> FSharedContext) then
    raise EVulkanError.Create('The destination bitmap or FMXLinux share context changed. Recreate the bridge.');
end;

procedure TVulkanFMXTexture.CopyToBitmap;
var
  Layout: Cardinal;
begin
  MakeCurrent;
  try
    Layout := GL_LAYOUT_GENERAL_EXT;
    FGL.WaitSemaphore(FGLReady, 0, nil, 1, @FGLTexture, @Layout);
    FGL.Check('Wait for Vulkan ready semaphore');
    FGL.BlitToFMXBitmap(FReadFBO, FDrawFBO, FWidth, FHeight);
    FGL.SignalSemaphore(FGLDone, 0, nil, 1, @FGLTexture, @Layout);
    FGL.Check('Signal OpenGL done semaphore');
    FGL.Flush;
    FGL.Finish; // Keep the first implementation synchronous, as on Windows.
    FGL.Check('Wait, blit and release Vulkan/OpenGL texture');
  finally
    RestoreContext;
  end;
end;

procedure TVulkanFMXTexture.SubmitAndCopy(CommandBuffer: VkCommandBuffer; Fence: VkFence);
var
  Submit: VkSubmitInfo;
  WaitStage: VkPipelineStageFlags;
begin
  CheckContext;
  Submit := Default(VkSubmitInfo);
  Submit.sType := VK_STRUCTURE_TYPE_SUBMIT_INFO;
  Submit.commandBufferCount := 1;
  Submit.pCommandBuffers := @CommandBuffer;
  WaitStage := VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
  if FSubmitted then
  begin
    Submit.waitSemaphoreCount := 1;
    Submit.pWaitSemaphores := @FDone;
    Submit.pWaitDstStageMask := @WaitStage;
  end;
  Submit.signalSemaphoreCount := 1;
  Submit.pSignalSemaphores := @FReady;
  CheckVulkan(FDevice.API.vkResetFences(FDevice.Handle, 1, @Fence), 'vkResetFences');
  CheckVulkan(FDevice.API.vkQueueSubmit(FDevice.Queue, 1, @Submit, Fence), 'vkQueueSubmit');
  CheckVulkan(FDevice.API.vkWaitForFences(FDevice.Handle, 1, @Fence, 1, UInt64(5000000000)), 'vkWaitForFences');
  CopyToBitmap;
  FSubmitted := True;
end;

procedure TVulkanFMXTexture.ContextLost(const Sender: TObject; const Message: TMessage);
begin
  FValid := False;
  // Do not use an obsolete native context during delayed cleanup.
  FSharedContext := nil;
end;

destructor TVulkanFMXTexture.Destroy;
begin
  if FContextLostSubscription <> 0 then
    TMessageManager.DefaultManager.Unsubscribe(TContextLostMessage, FContextLostSubscription);
  if (FGL <> nil) and (FSharedContext <> nil) and
    ((FGLMemory <> 0) or (FGLReady <> 0) or (FGLDone <> 0)) then
  begin
    MakeCurrent;
    try
      FGL.Finish;
      if FReadFBO <> 0 then
        FGL.DeleteFramebuffers(1, @FReadFBO);
      if FDrawFBO <> 0 then
        FGL.DeleteFramebuffers(1, @FDrawFBO);
      if FGLTexture <> 0 then
        FGL.DeleteTextures(1, @FGLTexture);
      if FGLMemory <> 0 then
        FGL.DeleteMemoryObjects(1, @FGLMemory);
      if FGLReady <> 0 then
        FGL.DeleteSemaphores(1, @FGLReady);
      if FGLDone <> 0 then
        FGL.DeleteSemaphores(1, @FGLDone);
    finally
      RestoreContext;
    end;
  end;
  if FDevice <> nil then
  begin
    FDevice.API.vkDeviceWaitIdle(FDevice.Handle);
    if FReady <> 0 then
      FDevice.API.vkDestroySemaphore(FDevice.Handle, FReady, nil);
    if FDone <> 0 then
      FDevice.API.vkDestroySemaphore(FDevice.Handle, FDone, nil);
    if FView <> 0 then
      FDevice.API.vkDestroyImageView(FDevice.Handle, FView, nil);
    if FImage <> 0 then
      FDevice.API.vkDestroyImage(FDevice.Handle, FImage, nil);
    if FMemory <> 0 then
      FDevice.API.vkFreeMemory(FDevice.Handle, FMemory, nil);
  end;
  FDevice.Free;
  FGL.Free;
  inherited;
end;

end.

