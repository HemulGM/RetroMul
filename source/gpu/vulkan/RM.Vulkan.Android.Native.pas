unit RM.Vulkan.Android.Native;

// Android system APIs only. Keep newer AHardwareBuffer/EGL entrypoints dynamic
// so an unsupported device reports a capability error instead of failing load.
interface

{$ALIGN 8}

uses
  System.SysUtils;

const
  AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM = 1;
  AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE = UInt64(1) shl 8;
  AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT = UInt64(1) shl 9;
  EGL_NATIVE_BUFFER_ANDROID = $3140;
  EGL_IMAGE_PRESERVED_KHR = $30D2;
  EGL_SYNC_NATIVE_FENCE_ANDROID = $3144;
  EGL_SYNC_NATIVE_FENCE_FD_ANDROID = $3145;

type
  TAndroidHardwareBufferDesc = record
    Width, Height, Layers, Format: Cardinal;
    Usage: UInt64;
    Stride, Reserved0: Cardinal;
    Reserved1: UInt64;
  end;

  PAndroidHardwareBufferDesc = ^TAndroidHardwareBufferDesc;

  TAllocateHardwareBuffer = function(Desc: PAndroidHardwareBufferDesc; Buffer: PPointer): Integer; cdecl;

  TReleaseHardwareBuffer = procedure(Buffer: Pointer); cdecl;

  TGetNativeClientBuffer = function(Buffer: Pointer): Pointer; cdecl;

  TCreateImage = function(Display, Context: Pointer; Target: Cardinal; Buffer: Pointer; Attributes: PInteger): Pointer; cdecl;

  TDestroyImage = function(Display, Image: Pointer): Cardinal; cdecl;

  TImageTargetTexture = procedure(Target: Cardinal; Image: Pointer); cdecl;

  TCreateSync = function(Display: Pointer; SyncType: Cardinal; Attributes: PInteger): Pointer; cdecl;

  TDestroySync = function(Display, Sync: Pointer): Cardinal; cdecl;

  TWaitSync = function(Display, Sync: Pointer; Flags: Integer): Cardinal; cdecl;

  TDupNativeFenceFD = function(Display, Sync: Pointer): Integer; cdecl;

  TAndroidVulkanNative = class
  private
    FLibrary: NativeUInt;
    function EGLProc(const Name: AnsiString): Pointer;
  public
    Allocate: TAllocateHardwareBuffer;
    Release: TReleaseHardwareBuffer;
    GetNativeClientBuffer: TGetNativeClientBuffer;
    CreateImage: TCreateImage;
    DestroyImage: TDestroyImage;
    ImageTargetTexture: TImageTargetTexture;
    CreateSync: TCreateSync;
    DestroySync: TDestroySync;
    WaitSync: TWaitSync;
    DupNativeFenceFD: TDupNativeFenceFD;
    constructor Create(Display: Pointer);
    destructor Destroy; override;
  end;

procedure CheckAndroidGL(const Operation: string);

procedure CheckAndroidEGL(Value: Boolean; const Operation: string);

implementation

uses
  Androidapi.Egl, Androidapi.Gles2, RM.Vulkan.Loader;

procedure CheckAndroidGL(const Operation: string);
var
  Code: Cardinal;
begin
  Code := glGetError;
  if Code <> GL_NO_ERROR then
    raise EVulkanError.CreateFmt('%s failed (GLES error 0x%.4x).', [Operation, Code]);
end;

procedure CheckAndroidEGL(Value: Boolean; const Operation: string);
begin
  if not Value then
    raise EVulkanError.CreateFmt('%s failed (EGL error 0x%.4x).', [Operation, eglGetError]);
end;

constructor TAndroidVulkanNative.Create(Display: Pointer);
const
  Required: array[0..5] of string = ('EGL_KHR_image_base', 'EGL_ANDROID_image_native_buffer',
    'EGL_ANDROID_get_native_client_buffer', 'EGL_ANDROID_native_fence_sync',
    'EGL_KHR_fence_sync', 'EGL_KHR_wait_sync');
var
  Extensions: string;
begin
  inherited Create;
  FLibrary := LoadLibrary('libandroid.so');
  if FLibrary = 0 then
    raise EVulkanError.Create('The Android system library is unavailable.');
  Allocate := TAllocateHardwareBuffer(GetProcAddress(FLibrary, 'AHardwareBuffer_allocate'));
  Release := TReleaseHardwareBuffer(GetProcAddress(FLibrary, 'AHardwareBuffer_release'));
  if not Assigned(Allocate) or not Assigned(Release) then
    raise EVulkanError.Create('AHardwareBuffer requires Android API 26 or later.');
  Extensions := ' ' + string(UTF8String(eglQueryString(Display, EGL_EXTENSIONS))) + ' ';
  for var Extension in Required do
    if not Extensions.Contains(' ' + Extension + ' ') then
      raise EVulkanError.Create('The Android EGL driver lacks ' + Extension + '.');
  Extensions := ' ' + string(UTF8String(PAnsiChar(glGetString(GL_EXTENSIONS)))) + ' ';
  if not Extensions.Contains(' GL_OES_EGL_image ') then
    raise EVulkanError.Create('The GLES driver lacks GL_OES_EGL_image.');
  GetNativeClientBuffer := TGetNativeClientBuffer(EGLProc('eglGetNativeClientBufferANDROID'));
  CreateImage := TCreateImage(EGLProc('eglCreateImageKHR'));
  DestroyImage := TDestroyImage(EGLProc('eglDestroyImageKHR'));
  ImageTargetTexture := TImageTargetTexture(EGLProc('glEGLImageTargetTexture2DOES'));
  CreateSync := TCreateSync(EGLProc('eglCreateSyncKHR'));
  DestroySync := TDestroySync(EGLProc('eglDestroySyncKHR'));
  WaitSync := TWaitSync(EGLProc('eglWaitSyncKHR'));
  DupNativeFenceFD := TDupNativeFenceFD(EGLProc('eglDupNativeFenceFDANDROID'));
end;

function TAndroidVulkanNative.EGLProc(const Name: AnsiString): Pointer;
begin
  Result := Pointer(eglGetProcAddress(PAnsiChar(Name)));
  if Result = nil then
    raise EVulkanError.Create('Missing Android EGL/GLES function: ' + string(Name));
end;

destructor TAndroidVulkanNative.Destroy;
begin
  if FLibrary <> 0 then
    FreeLibrary(FLibrary);
  inherited;
end;

end.

