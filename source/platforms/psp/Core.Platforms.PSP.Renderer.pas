unit Core.Platforms.PSP.Renderer;

// Owned by the PSP worker, inside Execute. The console and its memory outlive
// this session; Reset and LoadExec keep the same GE engine and memory objects.
interface

uses
  System.SysUtils, PSP.Console, PSP.GE.Backend, RM.Vulkan.TexScale;

type
  // CPU: PSP.GE.Raster, the reference. Vulkan LLE: the same pixel pipeline in
  // compute shaders, bit exact. Vulkan HLE: graphics pipelines, fast and not
  // bit exact.
  TPSPRenderer = (prCPU, prVulkanLLE, prVulkanHLE);

  TPSPRendererSession = class
  private
    FConsole: TPSPConsole;
    // The renderer (owned), and what the GE engine draws through.
    FBackend: TObject;
    FEngineBackend: TGERasterBackend;
    FKind: TPSPRenderer;
    FDescription: string;
  public
    // Scale: the Vulkan HLE renderer's internal resolution (1 to 8 times the PSP's);
    // TextureScale and TextureFilter: its texture scaling above 1x (0 none,
    // else 2 to 6).
    constructor Create(Console: TPSPConsole; Renderer: TPSPRenderer; Scale: Integer = 1; TextureScale: Integer = 0;
      TextureFilter: TTexScaleFilter = tfXBRZ);
    destructor Destroy; override;
    function Status: string;
  end;

// The settings' values: cpu, vulkan (LLE, also read as vulkan-lle), vulkan-hle.
// Anything else is the CPU.
function PSPRendererName(Renderer: TPSPRenderer): string;
function PSPRendererFromName(const Name: string): TPSPRenderer;

implementation

uses
  PSP.GE
{$IF (Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID)) and not Defined(CPUX86)}
    , PSP.GE.VulkanLLE, PSP.GE.VulkanHLE
{$ENDIF}
    ;

function PSPRendererName(Renderer: TPSPRenderer): string;
begin
  case Renderer of
    prVulkanLLE:
      Result := 'vulkan';
    prVulkanHLE:
      Result := 'vulkan-hle';
  else
    Result := 'cpu';
  end;
end;

function PSPRendererFromName(const Name: string): TPSPRenderer;
begin
  if SameText(Name, 'vulkan') or SameText(Name, 'vulkan-lle') then
    Result := prVulkanLLE
  else if SameText(Name, 'vulkan-hle') then
    Result := prVulkanHLE
  else
    Result := prCPU;
end;

constructor TPSPRendererSession.Create(Console: TPSPConsole; Renderer: TPSPRenderer; Scale, TextureScale: Integer;
  TextureFilter: TTexScaleFilter);
begin
  inherited Create;
  FConsole := Console;
  FDescription := 'cpu';
  if Renderer = prCPU then
    Exit;
  var Reason: string;
{$IF (Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID)) and not Defined(CPUX86)}
  if Renderer = prVulkanHLE then
  begin
    var Backend: TGEVulkanHLEBackend;
    if CreateGEVulkanHLEBackend(Console.Memory, Backend, Reason, '', Scale) then
    begin
      FBackend := Backend;
      FEngineBackend := Backend.EngineBackend;
      FKind := prVulkanHLE;
      Backend.TextureScale := TextureScale;
      Backend.TextureFilter := TextureFilter;
      TPSPGE(Console.System.Find(TPSPGE)).Engine.Backend := FEngineBackend;
      // Frames come from its images, at its resolution.
      Console.OnPresent := Backend.Present;
      FDescription := 'vulkan-hle: ' + Backend.Compute.Name;
      if Backend.Scale > 1 then
      begin
        FDescription := FDescription + Format(' at %dx', [Backend.Scale]);
        if Backend.TextureScale > 1 then
          FDescription := FDescription + Format(', textures %dx %s',
            [Backend.TextureScale, TexScaleFilterName(Backend.TextureFilter)]);
      end;
      Console.HLE.Log('gpu: ' + FDescription);
      Exit;
    end;
  end
  else
  begin
    var Backend: TGEVulkanLLEBackend;
    if CreateGEVulkanLLEBackend(Console.Memory, False, Backend, Reason) then
    begin
      FBackend := Backend;
      FEngineBackend := Backend;
      FKind := prVulkanLLE;
      Backend.OnMessage :=
        procedure(const Text: string)
        begin
          FConsole.HLE.Log(Text);
        end;
      TPSPGE(Console.System.Find(TPSPGE)).Engine.Backend := Backend;
      FDescription := 'vulkan: ' + Backend.Compute.Name;
      Console.HLE.Log('gpu: ' + FDescription);
      Exit;
    end;
  end;
{$ELSE}
  Reason := 'this host is not qualified for Vulkan GE rendering';
{$ENDIF}
  FDescription := 'cpu: Vulkan unavailable (' + Reason + ')';
  Console.HLE.Log('gpu: unavailable (' + Reason + '), the GE draws on the CPU');
end;

destructor TPSPRendererSession.Destroy;
begin
  if FBackend <> nil then
  begin
    if FKind = prVulkanHLE then
      FConsole.OnPresent := nil;
    var GE := TPSPGE(FConsole.System.Find(TPSPGE));
    if GE.Engine.Backend = FEngineBackend then
      GE.Engine.Backend := nil;
    FBackend.Free;
  end;
  inherited;
end;

function TPSPRendererSession.Status: string;
begin
  Result := FDescription;
{$IF (Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID)) and not Defined(CPUX86)}
  if FBackend = nil then
    Exit;
  if FKind = prVulkanHLE then
  begin
    var S := TGEVulkanHLEBackend(FBackend).Stats;
    Result := Result + Format(' (%d primitives in %d draws, %d read backs)', [S.Prims, S.Draws, S.Readbacks]);
  end
  else
  begin
    var S := TGEVulkanLLEBackend(FBackend).Stats;
    Result := Result + Format(' (%d batches, %d GPU primitives, %d CPU fallbacks)', [S.Batches, S.Prims, S.Fallbacks]);
  end;
{$ENDIF}
end;

end.
