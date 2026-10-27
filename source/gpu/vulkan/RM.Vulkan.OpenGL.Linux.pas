unit RM.Vulkan.OpenGL.Linux;

// The small OpenGL subset needed for Vulkan external-object interop. Functions
// come from the system libGL, with GLX dispatch for driver extension entrypoints.
interface

uses
  System.SysUtils;

const
  GL_NO_ERROR = 0;
  GL_RENDERER = $1F01;
  GL_EXTENSIONS = $1F03;
  GL_TEXTURE_2D = $0DE1;
  GL_TEXTURE_BINDING_2D = $8069;
  GL_TEXTURE_MIN_FILTER = $2801;
  GL_TEXTURE_MAG_FILTER = $2800;
  GL_NEAREST = $2600;
  GL_RGBA8 = $8058;
  GL_FRAMEBUFFER = $8D40;
  GL_READ_FRAMEBUFFER = $8CA8;
  GL_DRAW_FRAMEBUFFER = $8CA9;
  GL_READ_FRAMEBUFFER_BINDING = $8CAA;
  GL_DRAW_FRAMEBUFFER_BINDING = $8CA6;
  GL_FRAMEBUFFER_COMPLETE = $8CD5;
  GL_COLOR_ATTACHMENT0 = $8CE0;
  GL_COLOR_BUFFER_BIT = $4000;
  GL_SCISSOR_TEST = $0C11;
  GL_FRAMEBUFFER_SRGB = $8DB9;
  GL_TEXTURE_TILING_EXT = $9580;
  GL_DEDICATED_MEMORY_OBJECT_EXT = $9581;
  GL_OPTIMAL_TILING_EXT = $9584;
  GL_HANDLE_TYPE_OPAQUE_FD_EXT = $9586;
  GL_LAYOUT_GENERAL_EXT = $958D;
  GL_NUM_DEVICE_UUIDS_EXT = $9596;
  GL_DEVICE_UUID_EXT = $9597;
  GL_DRIVER_UUID_EXT = $9598;

type
  TGLGetProcAddress = function(Name: PAnsiChar): Pointer; cdecl;

  TGLGetString = function(Name: Cardinal): PAnsiChar; cdecl;

  TGLGetIntegerv = procedure(Name: Cardinal; Value: PInteger); cdecl;

  TGLGetError = function: Cardinal; cdecl;

  TGLGetUnsignedBytev = procedure(Name: Cardinal; Value: Pointer); cdecl;

  TGLGetUnsignedByteiv = procedure(Name, Index: Cardinal; Value: Pointer); cdecl;

  TGLGenObjects = procedure(Count: Integer; Objects: PCardinal); cdecl;

  TGLDeleteObjects = procedure(Count: Integer; Objects: PCardinal); cdecl;

  TGLBindObject = procedure(Target, Name: Cardinal); cdecl;

  TGLTexParameteri = procedure(Target, Name: Cardinal; Value: Integer); cdecl;

  TGLMemoryParameteri = procedure(Memory, Name: Cardinal; Value: PInteger); cdecl;

  TGLImportMemoryFd = procedure(Memory: Cardinal; Size: UInt64; HandleType: Cardinal; FD: Integer); cdecl;

  TGLTexStorageMem2D = procedure(Target: Cardinal; Levels: Integer; InternalFormat: Cardinal; Width, Height: Integer; Memory: Cardinal; Offset: UInt64); cdecl;

  TGLImportSemaphoreFd = procedure(Semaphore, HandleType: Cardinal; FD: Integer); cdecl;

  TGLSemaphoreBarrier = procedure(Semaphore, BufferCount: Cardinal; Buffers: PCardinal; TextureCount: Cardinal; Textures, Layouts: PCardinal); cdecl;

  TGLFramebufferTexture2D = procedure(Target, Attachment, TextureTarget, Texture: Cardinal; Level: Integer); cdecl;

  TGLCheckFramebufferStatus = function(Target: Cardinal): Cardinal; cdecl;

  TGLBlitFramebuffer = procedure(SrcX0, SrcY0, SrcX1, SrcY1, DstX0, DstY0, DstX1, DstY1: Integer; Mask, Filter: Cardinal); cdecl;

  TGLSetCapability = procedure(Capability: Cardinal); cdecl;

  TGLIsEnabled = function(Capability: Cardinal): Byte; cdecl;

  TGLFlush = procedure; cdecl;

  TVulkanOpenGL = class
  private
    FLibrary: NativeUInt;
    FGetProcAddress: TGLGetProcAddress;
    FRenderer: string;
    function Proc(const Name: AnsiString): Pointer;
  public
    GetString: TGLGetString;
    GetIntegerv: TGLGetIntegerv;
    GetError: TGLGetError;
    GetUnsignedBytev: TGLGetUnsignedBytev;
    GetUnsignedByteiv: TGLGetUnsignedByteiv;
    GenTextures, GenFramebuffers, CreateMemoryObjects, GenSemaphores: TGLGenObjects;
    DeleteTextures, DeleteFramebuffers, DeleteMemoryObjects, DeleteSemaphores: TGLDeleteObjects;
    BindTexture, BindFramebuffer: TGLBindObject;
    TexParameteri: TGLTexParameteri;
    MemoryObjectParameteriv: TGLMemoryParameteri;
    ImportMemoryFd: TGLImportMemoryFd;
    TexStorageMem2D: TGLTexStorageMem2D;
    ImportSemaphoreFd: TGLImportSemaphoreFd;
    WaitSemaphore, SignalSemaphore: TGLSemaphoreBarrier;
    FramebufferTexture2D: TGLFramebufferTexture2D;
    CheckFramebufferStatus: TGLCheckFramebufferStatus;
    BlitFramebuffer: TGLBlitFramebuffer;
    Enable, Disable: TGLSetCapability;
    IsEnabled: TGLIsEnabled;
    Flush, Finish: TGLFlush;
    constructor Create(RequireExternalObjects: Boolean = True);
    destructor Destroy; override;
    procedure Check(const Operation: string);
    procedure BlitToFMXBitmap(ReadFBO, DrawFBO: Cardinal; Width, Height: Integer);
    property Renderer: string read FRenderer;
  end;

implementation

uses
  RM.Vulkan.Loader;

constructor TVulkanOpenGL.Create(RequireExternalObjects: Boolean);
const
  Required: array[0..3] of string = ('GL_EXT_memory_object', 'GL_EXT_memory_object_fd',
    'GL_EXT_semaphore', 'GL_EXT_semaphore_fd');
var
  Extensions: string;
  Text: PAnsiChar;
begin
  inherited Create;
  FLibrary := LoadLibrary('libGL.so.1');
  if FLibrary = 0 then
    raise EVulkanError.Create('The system OpenGL library libGL.so.1 is unavailable.');
  FGetProcAddress := TGLGetProcAddress(GetProcAddress(FLibrary, 'glXGetProcAddressARB'));
  GetString := TGLGetString(Proc('glGetString'));
  GetIntegerv := TGLGetIntegerv(Proc('glGetIntegerv'));
  GetError := TGLGetError(Proc('glGetError'));
  Text := GetString(GL_RENDERER);
  if Text = nil then
    raise EVulkanError.Create('No current FMXLinux OpenGL context.');
  FRenderer := string(UTF8String(Text));
  Text := GetString(GL_EXTENSIONS);
  if Text = nil then
    raise EVulkanError.Create('FMXLinux requires an OpenGL compatibility context.');
  Extensions := ' ' + string(UTF8String(Text)) + ' ';
  for var Extension in Required do
    if RequireExternalObjects and not Extensions.Contains(' ' + Extension + ' ') then
      raise EVulkanError.CreateFmt('OpenGL renderer "%s" lacks %s. Vulkan texture sharing requires external memory and semaphore FD support.', [FRenderer, Extension]);
  if RequireExternalObjects then
  begin
    GetUnsignedBytev := TGLGetUnsignedBytev(Proc('glGetUnsignedBytevEXT'));
    GetUnsignedByteiv := TGLGetUnsignedByteiv(Proc('glGetUnsignedBytei_vEXT'));
    CreateMemoryObjects := TGLGenObjects(Proc('glCreateMemoryObjectsEXT'));
    GenSemaphores := TGLGenObjects(Proc('glGenSemaphoresEXT'));
    DeleteMemoryObjects := TGLDeleteObjects(Proc('glDeleteMemoryObjectsEXT'));
    DeleteSemaphores := TGLDeleteObjects(Proc('glDeleteSemaphoresEXT'));
    MemoryObjectParameteriv := TGLMemoryParameteri(Proc('glMemoryObjectParameterivEXT'));
    ImportMemoryFd := TGLImportMemoryFd(Proc('glImportMemoryFdEXT'));
    TexStorageMem2D := TGLTexStorageMem2D(Proc('glTexStorageMem2DEXT'));
    ImportSemaphoreFd := TGLImportSemaphoreFd(Proc('glImportSemaphoreFdEXT'));
    WaitSemaphore := TGLSemaphoreBarrier(Proc('glWaitSemaphoreEXT'));
    SignalSemaphore := TGLSemaphoreBarrier(Proc('glSignalSemaphoreEXT'));
  end;
  GenTextures := TGLGenObjects(Proc('glGenTextures'));
  GenFramebuffers := TGLGenObjects(Proc('glGenFramebuffers'));
  DeleteTextures := TGLDeleteObjects(Proc('glDeleteTextures'));
  DeleteFramebuffers := TGLDeleteObjects(Proc('glDeleteFramebuffers'));
  BindTexture := TGLBindObject(Proc('glBindTexture'));
  BindFramebuffer := TGLBindObject(Proc('glBindFramebuffer'));
  TexParameteri := TGLTexParameteri(Proc('glTexParameteri'));
  FramebufferTexture2D := TGLFramebufferTexture2D(Proc('glFramebufferTexture2D'));
  CheckFramebufferStatus := TGLCheckFramebufferStatus(Proc('glCheckFramebufferStatus'));
  BlitFramebuffer := TGLBlitFramebuffer(Proc('glBlitFramebuffer'));
  Enable := TGLSetCapability(Proc('glEnable'));
  Disable := TGLSetCapability(Proc('glDisable'));
  IsEnabled := TGLIsEnabled(Proc('glIsEnabled'));
  Flush := TGLFlush(Proc('glFlush'));
  Finish := TGLFlush(Proc('glFinish'));
  Check('OpenGL external-object initialization');
end;

function TVulkanOpenGL.Proc(const Name: AnsiString): Pointer;
begin
  Result := GetProcAddress(FLibrary, PChar(string(Name)));
  if (Result = nil) and Assigned(FGetProcAddress) then
    Result := FGetProcAddress(PAnsiChar(Name));
  if Result = nil then
    raise EVulkanError.Create('Missing OpenGL function: ' + string(Name));
end;

procedure TVulkanOpenGL.Check(const Operation: string);
var
  Code: Cardinal;
begin
  Code := GetError;
  if Code <> GL_NO_ERROR then
    raise EVulkanError.CreateFmt('%s failed (OpenGL error 0x%.4x).', [Operation, Code]);
end;

destructor TVulkanOpenGL.Destroy;
begin
  if FLibrary <> 0 then
    FreeLibrary(FLibrary);
  inherited;
end;

procedure TVulkanOpenGL.BlitToFMXBitmap(ReadFBO, DrawFBO: Cardinal; Width, Height: Integer);
var
  OldRead, OldDraw: Integer;
  Scissor, SRGB: Boolean;
begin
  GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, @OldRead);
  GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, @OldDraw);
  Scissor := IsEnabled(GL_SCISSOR_TEST) <> 0;
  SRGB := IsEnabled(GL_FRAMEBUFFER_SRGB) <> 0;
  try
    Disable(GL_SCISSOR_TEST);
    Disable(GL_FRAMEBUFFER_SRGB);
    BindFramebuffer(GL_READ_FRAMEBUFFER, ReadFBO);
    BindFramebuffer(GL_DRAW_FRAMEBUFFER, DrawFBO);
    // Vulkan image rows start at the top. FMX OpenGL render targets expect
    // bottom-up rows and reverse texture coordinates when painting them.
    BlitFramebuffer(0, 0, Width, Height, 0, Height, Width, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    Check('OpenGL blit into FMXLinux bitmap');
  finally
    BindFramebuffer(GL_READ_FRAMEBUFFER, OldRead);
    BindFramebuffer(GL_DRAW_FRAMEBUFFER, OldDraw);
    if Scissor then
      Enable(GL_SCISSOR_TEST);
    if SRGB then
      Enable(GL_FRAMEBUFFER_SRGB);
  end;
end;

end.

