unit RM.Vulkan.FMX.Android;

// Vulkan -> AHardwareBuffer -> EGLImage -> GPU draw into FMX TBitmap.
// UI thread; one frame in flight. Native fence FDs synchronize both APIs.
interface

uses
  System.SysUtils, System.Messaging, FMX.Graphics, FMX.Types3D,
  RM.Vulkan.Bindings, RM.Vulkan.Device, RM.Vulkan.Android.Native;

type
  TVulkanFMXTexture = class
  private
    FBitmap: TBitmap; // Borrowed; never resize while this bridge is alive.
    FBitmapTexture: TTexture;
    FBitmapHandle: NativeUInt;
    FDevice: TVulkanDevice;
    FNative: TAndroidVulkanNative;
    FBuffer, FEGLImage: Pointer;
    FDisplay, FSharedContext, FContext, FSurface: Pointer;
    FOldDisplay, FOldContext, FOldRead, FOldDraw: Pointer;
    FImage: VkImage;
    FMemory: VkDeviceMemory;
    FView: VkImageView;
    FReady, FDone: VkSemaphore;
    FGLTexture, FFramebuffer, FProgram, FVertices: Cardinal;
    FWidth, FHeight: Integer;
    FFormat: VkFormat;
    FExternalQueueFamily: Cardinal;
    FSubmitted, FValid, FContextLost: Boolean;
    FContextLostSubscription: Integer;
    procedure ContextLost(const Sender: TObject; const Message: TMessage);
    procedure MakeCurrent;
    procedure RestoreContext;
    procedure CreateImage;
    procedure CreateSemaphores;
    procedure CreateGLResources;
    procedure CopyToBitmap;
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
    property InitialQueueFamily: Cardinal read FExternalQueueFamily;
    property ExternalQueueFamily: Cardinal read FExternalQueueFamily;
  end;

implementation

uses
  Posix.Unistd, Androidapi.Egl, Androidapi.Gles2, FMX.Canvas.GPU,
  FMX.Context.GLES.Android, RM.Vulkan.Loader;

procedure TVulkanFMXTexture.MakeCurrent;
begin
  FOldDisplay := eglGetCurrentDisplay;
  FOldContext := eglGetCurrentContext;
  FOldRead := eglGetCurrentSurface(EGL_READ);
  FOldDraw := eglGetCurrentSurface(EGL_DRAW);
  CheckAndroidEGL(eglMakeCurrent(FDisplay, FSurface, FSurface, FContext) <> 0,
    'Activate Vulkan bitmap GLES context');
end;

procedure TVulkanFMXTexture.RestoreContext;
begin
  if FOldDisplay <> nil then
    CheckAndroidEGL(eglMakeCurrent(FOldDisplay, FOldDraw, FOldRead, FOldContext) <> 0,
      'Restore FMX EGL context')
  else
    CheckAndroidEGL(eglMakeCurrent(FDisplay, nil, nil, nil) <> 0, 'Release EGL context');
end;

constructor TVulkanFMXTexture.Create(Bitmap: TBitmap; Width, Height: Integer);
const
  ContextAttributes: array[0..2] of Integer = (EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE);
  SurfaceAttributes: array[0..4] of Integer = (EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE);
var
  BitmapObject: TObject;
begin
  inherited Create;
  if (Bitmap = nil) or (Width <= 0) or (Height <= 0) then
    raise EArgumentException.Create('A bitmap and positive texture dimensions are required.');
  if not TCanvasManager.DefaultCanvas.InheritsFrom(TCustomCanvasGpu) then
    raise EVulkanError.Create('Android Vulkan sharing requires the FMX GPU canvas.');
  if not TContextManager.DefaultContextClass.InheritsFrom(TCustomAndroidContext) then
    raise EVulkanError.Create('Android Vulkan sharing requires the FMX GLES context.');
  if not TCustomAndroidContext.Valid then
    raise EVulkanError.Create('The Android FMX GLES context is unavailable.');
  FBitmap := Bitmap;
  FWidth := Width;
  FHeight := Height;
  FFormat := VK_FORMAT_R8G8B8A8_UNORM;
  // Native Android buffers are FOREIGN unless matching API UUIDs prove otherwise.
  FExternalQueueFamily := VK_QUEUE_FAMILY_FOREIGN_EXT;
  FDisplay := TCustomAndroidContext.SharedDisplay;
  FSharedContext := TCustomAndroidContext.SharedContext;
  FContext := eglCreateContext(FDisplay, TCustomAndroidContext.SharedConfig,
    FSharedContext, @ContextAttributes[0]);
  CheckAndroidEGL(FContext <> nil, 'Create shared GLES2 copy context');
  FSurface := eglCreatePbufferSurface(FDisplay, TCustomAndroidContext.SharedConfig, @SurfaceAttributes[0]);
  CheckAndroidEGL(FSurface <> nil, 'Create GLES copy pbuffer');
  FBitmap.SetSize(Width, Height);
  FBitmapHandle := FBitmap.Handle;
  BitmapObject := TObject(FBitmapHandle);
  if not (BitmapObject is TBitmapCtx) then
    raise EVulkanError.Create('The Android bitmap is not backed by TBitmapCtx.');
  FBitmapTexture := TBitmapCtx(BitmapObject).RenderTarget;
  FBitmapTexture.Initialize;
  // Publish the destination texture's allocation before another context uses it.
  glFinish;
  MakeCurrent;
  try
    FNative := TAndroidVulkanNative.Create(FDisplay);
    FDevice := TVulkanDevice.Create;
    CreateImage;
    CreateSemaphores;
    CreateGLResources;
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
  Usage: VkAndroidHardwareBufferUsageANDROID;
  FormatProperties: VkImageFormatProperties2;
  Desc: TAndroidHardwareBufferDesc;
  BufferProperties: VkAndroidHardwareBufferPropertiesANDROID;
  BufferFormat: VkAndroidHardwareBufferFormatPropertiesANDROID;
  ExternalImage: VkExternalMemoryImageCreateInfo;
  ImageInfo: VkImageCreateInfo;
  ImportInfo: VkImportAndroidHardwareBufferInfoANDROID;
  Dedicated: VkMemoryDedicatedAllocateInfo;
  AllocateInfo: VkMemoryAllocateInfo;
  ViewInfo: VkImageViewCreateInfo;
  Code: Integer;
begin
  ExternalInfo := Default(VkPhysicalDeviceExternalImageFormatInfo);
  ExternalInfo.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO;
  ExternalInfo.handleType := VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID;
  FormatInfo := Default(VkPhysicalDeviceImageFormatInfo2);
  FormatInfo.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2;
  FormatInfo.pNext := @ExternalInfo;
  FormatInfo.format := FFormat;
  FormatInfo.&type := VK_IMAGE_TYPE_2D;
  FormatInfo.tiling := VK_IMAGE_TILING_OPTIMAL;
  FormatInfo.usage := VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT or VK_IMAGE_USAGE_SAMPLED_BIT;
  Usage := Default(VkAndroidHardwareBufferUsageANDROID);
  Usage.sType := VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_USAGE_ANDROID;
  ExternalProperties := Default(VkExternalImageFormatProperties);
  ExternalProperties.sType := VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES;
  ExternalProperties.pNext := @Usage;
  FormatProperties := Default(VkImageFormatProperties2);
  FormatProperties.sType := VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
  FormatProperties.pNext := @ExternalProperties;
  CheckVulkan(FDevice.API.vkGetPhysicalDeviceImageFormatProperties2(FDevice.PhysicalDevice,
      @FormatInfo, @FormatProperties), 'Check RGBA8 AHardwareBuffer import');
  if ExternalProperties.externalMemoryProperties.externalMemoryFeatures and VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT = 0 then
    raise EVulkanError.Create('The Vulkan driver cannot import an RGBA8 AHardwareBuffer.');
  if (Cardinal(FWidth) > FormatProperties.imageFormatProperties.maxExtent.width) or
    (Cardinal(FHeight) > FormatProperties.imageFormatProperties.maxExtent.height) then
    raise EVulkanError.Create('The Android buffer exceeds the Vulkan image size limit.');
  Desc := Default(TAndroidHardwareBufferDesc);
  Desc.Width := FWidth;
  Desc.Height := FHeight;
  Desc.Layers := 1;
  Desc.Format := AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
  Desc.Usage := Usage.androidHardwareBufferUsage or AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE or
    AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT;
  Code := FNative.Allocate(@Desc, @FBuffer);
  if (Code <> 0) or (FBuffer = nil) then
    raise EVulkanError.CreateFmt('AHardwareBuffer_allocate failed (%d).', [Code]);
  BufferFormat := Default(VkAndroidHardwareBufferFormatPropertiesANDROID);
  BufferFormat.sType := VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID;
  BufferProperties := Default(VkAndroidHardwareBufferPropertiesANDROID);
  BufferProperties.sType := VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID;
  BufferProperties.pNext := @BufferFormat;
  CheckVulkan(FDevice.API.vkGetAndroidHardwareBufferPropertiesANDROID(FDevice.Handle, FBuffer,
      @BufferProperties), 'vkGetAndroidHardwareBufferPropertiesANDROID');
  if (BufferFormat.format <> FFormat) or
    (BufferFormat.formatFeatures and VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT = 0) or
    (BufferFormat.formatFeatures and VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT = 0) then
    raise EVulkanError.Create('The native Android buffer does not support RGBA8 rendering and sampling.');
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
  CheckVulkan(FDevice.API.vkCreateImage(FDevice.Handle, @ImageInfo, nil, @FImage), 'Create AHardwareBuffer image');
  Dedicated := Default(VkMemoryDedicatedAllocateInfo);
  Dedicated.sType := VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
  Dedicated.image := FImage;
  ImportInfo := Default(VkImportAndroidHardwareBufferInfoANDROID);
  ImportInfo.sType := VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID;
  ImportInfo.pNext := @Dedicated;
  ImportInfo.buffer := FBuffer;
  AllocateInfo := Default(VkMemoryAllocateInfo);
  AllocateInfo.sType := VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  AllocateInfo.pNext := @ImportInfo;
  // AHardwareBuffer image memory requirements may not be queried before bind.
  AllocateInfo.allocationSize := BufferProperties.allocationSize;
  AllocateInfo.memoryTypeIndex := FDevice.MemoryType(BufferProperties.memoryTypeBits);
  CheckVulkan(FDevice.API.vkAllocateMemory(FDevice.Handle, @AllocateInfo, nil, @FMemory), 'Import AHardwareBuffer memory');
  CheckVulkan(FDevice.API.vkBindImageMemory(FDevice.Handle, FImage, FMemory, 0), 'Bind AHardwareBuffer memory');
  ViewInfo := Default(VkImageViewCreateInfo);
  ViewInfo.sType := VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
  ViewInfo.image := FImage;
  ViewInfo.viewType := VK_IMAGE_VIEW_TYPE_2D;
  ViewInfo.format := FFormat;
  ViewInfo.subresourceRange.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  ViewInfo.subresourceRange.levelCount := 1;
  ViewInfo.subresourceRange.layerCount := 1;
  CheckVulkan(FDevice.API.vkCreateImageView(FDevice.Handle, @ViewInfo, nil, @FView), 'Create Android image view');
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
  ExternalInfo.handleType := VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
  Properties := Default(VkExternalSemaphoreProperties);
  Properties.sType := VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES;
  FDevice.API.vkGetPhysicalDeviceExternalSemaphoreProperties(FDevice.PhysicalDevice, @ExternalInfo, @Properties);
  if (Properties.externalSemaphoreFeatures and VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT = 0) or
    (Properties.externalSemaphoreFeatures and VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT = 0) then
    raise EVulkanError.Create('The Android Vulkan driver must import and export SYNC_FD binary semaphores.');
  ExportInfo := Default(VkExportSemaphoreCreateInfo);
  ExportInfo.sType := VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO;
  ExportInfo.handleTypes := ExternalInfo.handleType;
  Info := Default(VkSemaphoreCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
  Info.pNext := @ExportInfo;
  CheckVulkan(FDevice.API.vkCreateSemaphore(FDevice.Handle, @Info, nil, @FReady), 'Create Android ready semaphore');
  Info.pNext := nil;
  CheckVulkan(FDevice.API.vkCreateSemaphore(FDevice.Handle, @Info, nil, @FDone), 'Create Android done semaphore');
end;

procedure TVulkanFMXTexture.CreateGLResources;
const
  ImageAttributes: array[0..2] of Integer = (EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE);
  VertexSource: AnsiString = 'attribute vec2 position; varying vec2 uv; void main() {' +
    'gl_Position=vec4(position,0.0,1.0); uv=position*0.5+0.5;}';
  FragmentSource: AnsiString = 'precision mediump float; varying vec2 uv; uniform sampler2D sourceImage;' +
    'void main(){gl_FragColor=texture2D(sourceImage,vec2(uv.x,1.0-uv.y));}';
  Vertices: array[0..5] of Single = (-1, -1, 3, -1, -1, 3);
var
  ClientBuffer: Pointer;
  VertexShader, FragmentShader: Cardinal;
  Linked: Integer;

  function Compile(Kind: Cardinal; const Source: AnsiString): Cardinal;
  var
    SourcePointer: PAnsiChar;
    Compiled, Length: Integer;
    Log: array[0..1023] of AnsiChar;
  begin
    Result := glCreateShader(Kind);
    SourcePointer := PAnsiChar(Source);
    glShaderSource(Result, 1, @SourcePointer, nil);
    glCompileShader(Result);
    glGetShaderiv(Result, GL_COMPILE_STATUS, @Compiled);
    if Compiled = 0 then
    begin
      glGetShaderInfoLog(Result, SizeOf(Log), @Length, @Log[0]);
      glDeleteShader(Result);
      raise EVulkanError.Create('GLES copy shader failed: ' + string(UTF8String(PAnsiChar(@Log[0]))));
    end;
  end;

begin
  ClientBuffer := FNative.GetNativeClientBuffer(FBuffer);
  CheckAndroidEGL(ClientBuffer <> nil, 'Get native EGL client buffer');
  FEGLImage := FNative.CreateImage(FDisplay, nil, EGL_NATIVE_BUFFER_ANDROID, ClientBuffer, @ImageAttributes[0]);
  CheckAndroidEGL(FEGLImage <> nil, 'Create Android EGLImage');
  glGenTextures(1, @FGLTexture);
  glBindTexture(GL_TEXTURE_2D, FGLTexture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  FNative.ImageTargetTexture(GL_TEXTURE_2D, FEGLImage);
  CheckAndroidGL('Import Android buffer into GLES texture');
  glGenFramebuffers(1, @FFramebuffer);
  glBindFramebuffer(GL_FRAMEBUFFER, FFramebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, Cardinal(FBitmapTexture.Handle), 0);
  if glCheckFramebufferStatus(GL_FRAMEBUFFER) <> GL_FRAMEBUFFER_COMPLETE then
    raise EVulkanError.Create('The Android FMX bitmap framebuffer is incomplete.');
  VertexShader := Compile(GL_VERTEX_SHADER, VertexSource);
  try
    FragmentShader := Compile(GL_FRAGMENT_SHADER, FragmentSource);
    try
      FProgram := glCreateProgram;
      glAttachShader(FProgram, VertexShader);
      glAttachShader(FProgram, FragmentShader);
      glBindAttribLocation(FProgram, 0, 'position');
      glLinkProgram(FProgram);
      glGetProgramiv(FProgram, GL_LINK_STATUS, @Linked);
      if Linked = 0 then
        raise EVulkanError.Create('Could not link the GLES bitmap copy program.');
    finally
      glDeleteShader(FragmentShader);
    end;
  finally
    glDeleteShader(VertexShader);
  end;
  glUseProgram(FProgram);
  glUniform1i(glGetUniformLocation(FProgram, 'sourceImage'), 0);
  glGenBuffers(1, @FVertices);
  glBindBuffer(GL_ARRAY_BUFFER, FVertices);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(Vertices), @Vertices[0], GL_STATIC_DRAW);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nil);
  glEnableVertexAttribArray(0);
  glViewport(0, 0, FWidth, FHeight);
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_STENCIL_TEST);
  glDisable(GL_SCISSOR_TEST);
  glDisable(GL_CULL_FACE);
  glDisable(GL_DITHER);
  CheckAndroidGL('Prepare GLES bitmap copy');
end;

procedure TVulkanFMXTexture.CopyToBitmap;
var
  Info: VkSemaphoreGetFdInfoKHR;
  ImportInfo: VkImportSemaphoreFdInfoKHR;
  FD: Integer;
  Attributes: array[0..2] of Integer;
  Sync: Pointer;
begin
  // FMX samples the destination from another GLES context. Complete its last
  // draw before this context overwrites that texture for the next frame.
  CheckAndroidEGL(TCustomAndroidContext.Valid, 'Activate FMX before bitmap transfer');
  glFinish;
  CheckAndroidGL('Complete previous FMX bitmap readers');
  MakeCurrent;
  try
    Info := Default(VkSemaphoreGetFdInfoKHR);
    Info.sType := VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
    Info.semaphore := FReady;
    Info.handleType := VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
    FD := -1;
    CheckVulkan(FDevice.API.vkGetSemaphoreFdKHR(FDevice.Handle, @Info, @FD), 'Export Vulkan ready native fence');
    try
      // -1 is a valid Vulkan SYNC_FD result meaning already signalled. Do not
      // pass it to EGL: EGL interprets -1 as a request to create a new fence.
      if FD >= 0 then
      begin
        Attributes[0] := EGL_SYNC_NATIVE_FENCE_FD_ANDROID;
        Attributes[1] := FD;
        Attributes[2] := EGL_NONE;
        Sync := FNative.CreateSync(FDisplay, EGL_SYNC_NATIVE_FENCE_ANDROID, @Attributes[0]);
        CheckAndroidEGL(Sync <> nil, 'Import Vulkan fence into EGL');
        FD := -1;
        try
          CheckAndroidEGL(FNative.WaitSync(FDisplay, Sync, 0) <> 0, 'Wait for Vulkan native fence');
        finally
          FNative.DestroySync(FDisplay, Sync);
        end;
      end;
    finally
      if FD >= 0 then
        __close(FD);
    end;
    glBindFramebuffer(GL_FRAMEBUFFER, FFramebuffer);
    glBindTexture(GL_TEXTURE_2D, FGLTexture);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    CheckAndroidGL('Draw Vulkan texture into Android FMX bitmap');
    Attributes[0] := EGL_NONE;
    Sync := FNative.CreateSync(FDisplay, EGL_SYNC_NATIVE_FENCE_ANDROID, @Attributes[0]);
    CheckAndroidEGL(Sync <> nil, 'Create GLES done native fence');
    FD := -1;
    try
      glFlush;
      FD := FNative.DupNativeFenceFD(FDisplay, Sync);
      CheckAndroidEGL(FD >= 0, 'Export GLES done native fence');
      ImportInfo := Default(VkImportSemaphoreFdInfoKHR);
      ImportInfo.sType := VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR;
      ImportInfo.semaphore := FDone;
      ImportInfo.flags := VK_SEMAPHORE_IMPORT_TEMPORARY_BIT;
      ImportInfo.handleType := VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
      ImportInfo.fd := FD;
      CheckVulkan(FDevice.API.vkImportSemaphoreFdKHR(FDevice.Handle, @ImportInfo), 'Import GLES done fence into Vulkan');
      FD := -1; // Vulkan consumes a successfully imported FD.
      // Publish destination writes before FMX samples it from its own context.
      glFinish;
      CheckAndroidGL('Complete Android bitmap GPU transfer');
    finally
      if FD >= 0 then
        __close(FD);
      FNative.DestroySync(FDisplay, Sync);
    end;
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

procedure TVulkanFMXTexture.CheckContext;
begin
  if not FValid or (TCustomAndroidContext.SharedContext <> FSharedContext) then
    raise EVulkanError.Create('The Android FMX GLES context was lost. Recreate the Vulkan bridge.');
  if (FBitmap.Handle <> FBitmapHandle) or (FBitmap.Width <> FWidth) or (FBitmap.Height <> FHeight) then
    raise EVulkanError.Create('The Android FMX bitmap changed. Recreate the Vulkan bridge.');
end;

procedure TVulkanFMXTexture.ContextLost(const Sender: TObject; const Message: TMessage);
begin
  FValid := False;
  FContextLost := True;
end;

destructor TVulkanFMXTexture.Destroy;
begin
  if FContextLostSubscription <> 0 then
    TMessageManager.DefaultManager.Unsubscribe(TContextLostMessage, FContextLostSubscription);
  if (FContext <> nil) and (FSurface <> nil) and not FContextLost then
  begin
    // Cleanup must not raise when EGL itself was lost during suspension.
    FOldDisplay := eglGetCurrentDisplay;
    FOldContext := eglGetCurrentContext;
    FOldRead := eglGetCurrentSurface(EGL_READ);
    FOldDraw := eglGetCurrentSurface(EGL_DRAW);
    if eglMakeCurrent(FDisplay, FSurface, FSurface, FContext) <> 0 then
    begin
      glFinish;
      if FFramebuffer <> 0 then
        glDeleteFramebuffers(1, @FFramebuffer);
      if FGLTexture <> 0 then
        glDeleteTextures(1, @FGLTexture);
      if FVertices <> 0 then
        glDeleteBuffers(1, @FVertices);
      if FProgram <> 0 then
        glDeleteProgram(FProgram);
      if FOldDisplay <> nil then
        eglMakeCurrent(FOldDisplay, FOldDraw, FOldRead, FOldContext)
      else
        eglMakeCurrent(FDisplay, nil, nil, nil);
    end;
  end;
  if FEGLImage <> nil then
    FNative.DestroyImage(FDisplay, FEGLImage);
  if FContext <> nil then
    eglDestroyContext(FDisplay, FContext);
  if FSurface <> nil then
    eglDestroySurface(FDisplay, FSurface);
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
  if FBuffer <> nil then
    FNative.Release(FBuffer);
  FDevice.Free;
  FNative.Free;
  inherited;
end;

end.

