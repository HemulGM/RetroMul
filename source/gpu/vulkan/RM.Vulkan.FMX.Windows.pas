unit RM.Vulkan.FMX.Windows;

// Windows D2D bridge: Vulkan imports a shared DXGI texture. Direct3D copies
// it into an ordinary FMX TBitmap on the GPU. No pixel mapping/readback is used.
interface

uses
  System.SysUtils, System.Rtti, System.Messaging, Winapi.Windows, Winapi.D3D10,
  Winapi.DXGI, Winapi.D2D1, FMX.Graphics, RM.Vulkan.Bindings, RM.Vulkan.Device;

type
  // The Windows SDK interface is absent from Delphi's public D2D headers.
  IVulkanD2DMultithread = interface(IUnknown)
    ['{31E6E7BC-E0FF-4D46-8C64-A0A8C41C15D3}']
    function GetMultithreadProtected: BOOL; stdcall;
    procedure Enter; stdcall;
    procedure Leave; stdcall;
  end;

  TVulkanFMXTexture = class
  private
    FBitmap: TBitmap; // Borrowed; the caller keeps it alive.
    FDevice: TVulkanDevice;
    FD3DDevice: ID3D10Device;
    FMultithread: IVulkanD2DMultithread;
    FSharedTexture, FBitmapTexture: ID3D10Texture2D;
    FCopyDone: ID3D10Query;
    FImage: VkImage;
    FMemory: VkDeviceMemory;
    FView: VkImageView;
    FWidth, FHeight: Integer;
    FFormat: VkFormat;
    FInitialQueueFamily: Cardinal;
    FExternalQueueFamily: Cardinal;
    FContextLostSubscription: Integer;
    FValid: Boolean;
    procedure ContextLost(const Sender: TObject; const Message: TMessage);
    procedure ImportTexture(SharedHandle: THandle);
    function BitmapTexture: ID3D10Texture2D;
  public
    constructor Create(Bitmap: TBitmap; Width, Height: Integer);
    destructor Destroy; override;
    // UI thread only. The command buffer must acquire ownership from EXTERNAL,
    // render, and release it back in GENERAL. One synchronous frame in flight.
    procedure SubmitAndCopy(CommandBuffer: VkCommandBuffer; Fence: VkFence);
    procedure CheckContext;
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
  System.TypInfo, Winapi.DXGIFormat, FMX.Types, FMX.Canvas.D2D, FMX.Types3D,
  RM.Vulkan.Loader;

procedure CheckDirect3D(ResultCode: HResult; const Operation: string);
begin
  if Failed(ResultCode) then
    raise EVulkanError.CreateFmt('%s failed (HRESULT 0x%.8x): %s', [Operation, Cardinal(ResultCode), SysErrorMessage(Cardinal(ResultCode))]);
end;

function CreateCompletionQuery(const Device: ID3D10Device; out Query: ID3D10Query): HResult;
type
  TCreateQuery = function(Self: Pointer; Description: Pointer; Output: Pointer): HResult; stdcall;

  TDeviceVTable = array[0..100] of Pointer;

  PDeviceVTable = ^TDeviceVTable;
var
  Description: TD3D10_QueryDesc;
  CreateQuery: TCreateQuery;
begin
  // Winapi.D3D10 declares the eight-byte descriptor as "const record". On
  // Win64 Delphi passes that by value, whereas COM requires a pointer. Call
  // the documented ID3D10Device slot with its native signature on both ABIs.
  Query := nil;
  Description := Default(TD3D10_QueryDesc);
  Description.Query := D3D10_QUERY_EVENT;
  CreateQuery := TCreateQuery(PDeviceVTable(PPointer(Pointer(Device))^)^[87]);
  Result := CreateQuery(Pointer(Device), @Description, @Query);
end;

constructor TVulkanFMXTexture.Create(Bitmap: TBitmap; Width, Height: Integer);
var
  DXGIDevice: IDXGIDevice;
  Adapter: IDXGIAdapter;
  AdapterDesc: TDXGIAdapterDesc;
  TextureDesc: TD3D10_Texture2DDesc;
  Resource: IDXGIResource;
  SharedHandle: THandle;
  LUID: UInt64;
begin
  inherited Create;
  if (Bitmap = nil) or (Width <= 0) or (Height <= 0) then
    raise EArgumentException.Create('A bitmap and positive texture dimensions are required.');
  if not TCanvasManager.DefaultCanvas.InheritsFrom(TCustomCanvasD2D) then
    raise EVulkanError.Create('This Windows demo requires the native FMX Direct2D canvas. Skia is not used.');
  FBitmap := Bitmap;
  FWidth := Width;
  FHeight := Height;
  FFormat := VK_FORMAT_B8G8R8A8_UNORM;
  FInitialQueueFamily := VK_QUEUE_FAMILY_EXTERNAL;
  FExternalQueueFamily := VK_QUEUE_FAMILY_EXTERNAL;
  FBitmap.SetSize(Width, Height);
  FD3DDevice := TCustomCanvasD2D.SharedDevice;
  FMultithread := TCustomCanvasD2D.SharedFactory as IVulkanD2DMultithread;
  DXGIDevice := FD3DDevice as IDXGIDevice;
  CheckDirect3D(DXGIDevice.GetAdapter(Adapter), 'DXGI GetAdapter');
  CheckDirect3D(Adapter.GetDesc(AdapterDesc), 'DXGI adapter GetDesc');
  Move(AdapterDesc.AdapterLuid, LUID, SizeOf(LUID));
  FDevice := TVulkanDevice.Create(LUID);
  FBitmapTexture := BitmapTexture;

  TextureDesc := Default(TD3D10_Texture2DDesc);
  TextureDesc.Width := Width;
  TextureDesc.Height := Height;
  TextureDesc.MipLevels := 1;
  TextureDesc.ArraySize := 1;
  TextureDesc.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
  TextureDesc.SampleDesc.Count := 1;
  TextureDesc.Usage := D3D10_USAGE_DEFAULT;
  TextureDesc.BindFlags := D3D10_BIND_RENDER_TARGET or D3D10_BIND_SHADER_RESOURCE;
  // The stock FMX D2D device uses DXGI 1.0 and cannot open keyed-mutex
  // resources. Use a legacy shared texture and explicitly complete each API's
  // GPU work before handing ownership to the other API (fence + D3D event).
  TextureDesc.MiscFlags := D3D10_RESOURCE_MISC_SHARED;
  FMultithread.Enter;
  try
    CheckDirect3D(FD3DDevice.CreateTexture2D(TextureDesc, nil, FSharedTexture), 'D3D10 CreateTexture2D (shared)');
    CheckDirect3D(CreateCompletionQuery(FD3DDevice, FCopyDone), 'D3D10 CreateQuery (copy completion)');
  finally
    FMultithread.Leave;
  end;
  Resource := FSharedTexture as IDXGIResource;
  CheckDirect3D(Resource.GetSharedHandle(SharedHandle), 'DXGI GetSharedHandle');
  // GetSharedHandle returns a KMT handle, not an owning NT handle. Do not call
  // CloseHandle on it. Keep FSharedTexture alive until Vulkan releases memory.
  ImportTexture(SharedHandle);
  FValid := True;
  FContextLostSubscription := TMessageManager.DefaultManager.SubscribeToMessage(TContextLostMessage, ContextLost);
end;

function TVulkanFMXTexture.BitmapTexture: ID3D10Texture2D;
var
  RTTI: TRttiContext;
  Handle: TObject;
  Field: TRttiField;
begin
  // FMX keeps TD2DBitmapHandle in its implementation section. Isolate this
  // version-dependent boundary and validate RTTI; never hard-code field offsets.
  Handle := TObject(FBitmap.Handle);
  if (Handle = nil) or (Handle.ClassName <> 'TD2DBitmapHandle') then
    raise EVulkanError.Create('The bitmap is not backed by the native FMX D2D canvas.');
  RTTI := TRttiContext.Create;
  try
    Field := RTTI.GetType(Handle.ClassType).GetField('FTexture');
    if (Field = nil) or (Field.FieldType.Handle <> TypeInfo(ID3D10Texture2D)) then
      raise EVulkanError.Create('This FMX version does not expose its bitmap texture through RTTI.');
    if not FBitmap.Canvas.BeginScene then
      raise EVulkanError.Create('Cannot initialize the FMX bitmap texture.');
    FBitmap.Canvas.EndScene;
    Result := Field.GetValue(Handle).AsInterface as ID3D10Texture2D;
    if Result = nil then
      raise EVulkanError.Create('FMX did not create the bitmap texture.');
  finally
    RTTI.Free;
  end;
end;

procedure TVulkanFMXTexture.ImportTexture(SharedHandle: THandle);
var
  ExternalInfo: VkPhysicalDeviceExternalImageFormatInfo;
  FormatInfo: VkPhysicalDeviceImageFormatInfo2;
  ExternalProperties: VkExternalImageFormatProperties;
  FormatProperties: VkImageFormatProperties2;
  ExternalImage: VkExternalMemoryImageCreateInfo;
  ImageInfo: VkImageCreateInfo;
  Requirements: VkMemoryRequirements;
  HandleProperties: VkMemoryWin32HandlePropertiesKHR;
  ImportInfo: VkImportMemoryWin32HandleInfoKHR;
  Dedicated: VkMemoryDedicatedAllocateInfo;
  AllocateInfo: VkMemoryAllocateInfo;
  ViewInfo: VkImageViewCreateInfo;
begin
  ExternalInfo := Default(VkPhysicalDeviceExternalImageFormatInfo);
  ExternalInfo.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO;
  ExternalInfo.handleType := VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT;
  FormatInfo := Default(VkPhysicalDeviceImageFormatInfo2);
  FormatInfo.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2;
  FormatInfo.pNext := @ExternalInfo;
  FormatInfo.format := VK_FORMAT_B8G8R8A8_UNORM;
  FormatInfo.&type := VK_IMAGE_TYPE_2D;
  FormatInfo.tiling := VK_IMAGE_TILING_OPTIMAL;
  FormatInfo.usage := VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT or VK_IMAGE_USAGE_SAMPLED_BIT;
  ExternalProperties := Default(VkExternalImageFormatProperties);
  ExternalProperties.sType := VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES;
  FormatProperties := Default(VkImageFormatProperties2);
  FormatProperties.sType := VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
  FormatProperties.pNext := @ExternalProperties;
  CheckVulkan(FDevice.API.vkGetPhysicalDeviceImageFormatProperties2(FDevice.PhysicalDevice,
      @FormatInfo, @FormatProperties), 'Check BGRA8 DXGI texture import');
  if ExternalProperties.externalMemoryProperties.externalMemoryFeatures and VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT = 0 then
    raise EVulkanError.Create('The Vulkan driver cannot import a BGRA8 Direct3D shared texture.');
  if (Cardinal(FWidth) > FormatProperties.imageFormatProperties.maxExtent.width) or
    (Cardinal(FHeight) > FormatProperties.imageFormatProperties.maxExtent.height) then
    raise EVulkanError.Create('The shared texture exceeds the Vulkan image size limit.');

  ExternalImage := Default(VkExternalMemoryImageCreateInfo);
  ExternalImage.sType := VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
  ExternalImage.handleTypes := VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT;
  ImageInfo := Default(VkImageCreateInfo);
  ImageInfo.sType := VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
  ImageInfo.pNext := @ExternalImage;
  ImageInfo.imageType := VK_IMAGE_TYPE_2D;
  ImageInfo.format := VK_FORMAT_B8G8R8A8_UNORM;
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
  CheckVulkan(FDevice.API.vkCreateImage(FDevice.Handle, @ImageInfo, nil, @FImage), 'vkCreateImage (shared BGRA8)');
  FDevice.API.vkGetImageMemoryRequirements(FDevice.Handle, FImage, @Requirements);
  HandleProperties := Default(VkMemoryWin32HandlePropertiesKHR);
  HandleProperties.sType := VK_STRUCTURE_TYPE_MEMORY_WIN32_HANDLE_PROPERTIES_KHR;
  CheckVulkan(FDevice.API.vkGetMemoryWin32HandlePropertiesKHR(FDevice.Handle,
      ExternalInfo.handleType, SharedHandle, @HandleProperties), 'vkGetMemoryWin32HandlePropertiesKHR');
  Dedicated := Default(VkMemoryDedicatedAllocateInfo);
  Dedicated.sType := VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
  Dedicated.image := FImage;
  ImportInfo := Default(VkImportMemoryWin32HandleInfoKHR);
  ImportInfo.sType := VK_STRUCTURE_TYPE_IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR;
  ImportInfo.pNext := @Dedicated;
  ImportInfo.handleType := ExternalInfo.handleType;
  ImportInfo.handle := SharedHandle;
  AllocateInfo := Default(VkMemoryAllocateInfo);
  AllocateInfo.sType := VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  AllocateInfo.pNext := @ImportInfo;
  AllocateInfo.allocationSize := Requirements.size;
  AllocateInfo.memoryTypeIndex := FDevice.MemoryType(Requirements.memoryTypeBits and HandleProperties.memoryTypeBits);
  CheckVulkan(FDevice.API.vkAllocateMemory(FDevice.Handle, @AllocateInfo, nil, @FMemory), 'vkAllocateMemory (DXGI import)');
  CheckVulkan(FDevice.API.vkBindImageMemory(FDevice.Handle, FImage, FMemory, 0), 'vkBindImageMemory');
  ViewInfo := Default(VkImageViewCreateInfo);
  ViewInfo.sType := VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
  ViewInfo.image := FImage;
  ViewInfo.viewType := VK_IMAGE_VIEW_TYPE_2D;
  ViewInfo.format := VK_FORMAT_B8G8R8A8_UNORM;
  ViewInfo.subresourceRange.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  ViewInfo.subresourceRange.levelCount := 1;
  ViewInfo.subresourceRange.layerCount := 1;
  CheckVulkan(FDevice.API.vkCreateImageView(FDevice.Handle, @ViewInfo, nil, @FView), 'vkCreateImageView');
end;

procedure TVulkanFMXTexture.ContextLost(const Sender: TObject; const Message: TMessage);
begin
  // Do not retain and render into a bitmap texture belonging to a lost device.
  // The frontend must recreate the bridge before rendering another frame.
  FValid := False;
end;

procedure TVulkanFMXTexture.CheckContext;
begin
  if not FValid then
    raise EVulkanError.Create('The FMX Direct3D context was recreated. Recreate the Vulkan bitmap bridge.');
  if (FBitmap.Width <> FWidth) or (FBitmap.Height <> FHeight) or
    (TCustomCanvasD2D.SharedDevice <> FD3DDevice) then
    raise EVulkanError.Create('The destination bitmap or FMX device changed. Recreate the Vulkan bitmap bridge.');
end;

procedure TVulkanFMXTexture.SubmitAndCopy(CommandBuffer: VkCommandBuffer; Fence: VkFence);
var
  Submit: VkSubmitInfo;
  ResultCode: HResult;
  Complete: BOOL;
  Deadline: UInt64;
begin
  CheckContext;
  Submit := Default(VkSubmitInfo);
  Submit.sType := VK_STRUCTURE_TYPE_SUBMIT_INFO;
  Submit.commandBufferCount := 1;
  Submit.pCommandBuffers := @CommandBuffer;
  CheckVulkan(FDevice.API.vkResetFences(FDevice.Handle, 1, @Fence), 'vkResetFences');
  CheckVulkan(FDevice.API.vkQueueSubmit(FDevice.Queue, 1, @Submit, Fence), 'vkQueueSubmit');
  CheckVulkan(FDevice.API.vkWaitForFences(FDevice.Handle, 1, @Fence, 1, UInt64(5000000000)), 'vkWaitForFences');

  FMultithread.Enter;
  try
    FD3DDevice.CopyResource(FBitmapTexture, FSharedTexture);
    FCopyDone._End;
    FD3DDevice.Flush;
    Deadline := GetTickCount64 + 5000;
    repeat
      Complete := False;
      ResultCode := FCopyDone.GetData(@Complete, SizeOf(Complete), Ord(D3D10_ASYNC_GETDATA_DONOTFLUSH));
      CheckDirect3D(ResultCode, 'D3D10 copy completion');
      if (ResultCode = S_OK) and Complete then
        Break;
      if GetTickCount64 >= Deadline then
        raise EVulkanError.Create('Timed out waiting for Direct3D to finish copying the shared texture.');
      SwitchToThread;
    until False;
    // Flush alone only submits work. The completed event guarantees that the
    // next Vulkan frame cannot overwrite the source while CopyResource reads it.
    if Failed(FD3DDevice.GetDeviceRemovedReason) then
      CheckDirect3D(FD3DDevice.GetDeviceRemovedReason, 'FMX Direct3D device');
  finally
    FMultithread.Leave;
  end;
end;

destructor TVulkanFMXTexture.Destroy;
begin
  if FContextLostSubscription <> 0 then
    TMessageManager.DefaultManager.Unsubscribe(TContextLostMessage, FContextLostSubscription);
  if FDevice <> nil then
  begin
    if Assigned(FDevice.API.vkDeviceWaitIdle) then
      FDevice.API.vkDeviceWaitIdle(FDevice.Handle);
    if FView <> 0 then
      FDevice.API.vkDestroyImageView(FDevice.Handle, FView, nil);
    if FImage <> 0 then
      FDevice.API.vkDestroyImage(FDevice.Handle, FImage, nil);
    if FMemory <> 0 then
      FDevice.API.vkFreeMemory(FDevice.Handle, FMemory, nil);
  end;
  FDevice.Free;
  // The KMT import borrows the Direct3D allocation until vkFreeMemory.
  FCopyDone := nil;
  FSharedTexture := nil;
  FBitmapTexture := nil;
  FD3DDevice := nil;
  inherited;
end;

end.

