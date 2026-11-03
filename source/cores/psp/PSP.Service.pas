unit PSP.Service;

// HLE services: each library implementation is a TPSPService registered by
// its unit's initialization section. The console creates them all, resets
// them, lets them register their NIDs and forwards scheduler events.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

{$RTTI EXPLICIT FIELDS([vcPrivate, vcProtected, vcPublic, vcPublished]) METHODS([vcPrivate, vcProtected, vcPublic,
  vcPublished]) PROPERTIES([vcPublic, vcPublished])}

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU,
  PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.IO, PSP.Loader, PSP.Display;

type
  TPSPService = class;

  TPSPServiceClass = class of TPSPService;

  // What a service may reach.
  TPSPSystem = class
  public
    Memory: TPSPMemory;
    CPU: TPSPCPU;
    HLE: TPSPHLE;
    Kernel: TPSPKernel;
    Scheduler: TPSPScheduler;
    IO: TPSPIO;
    Loader: TPSPLoader;
    Display: TPSPDisplay;
    Services: TObjectList<TPSPService>;
    // Folder with firmware data the user supplied (fonts), may be empty.
    FlashRoot: string;
    // Optional user-supplied PGF files; accessed read-only by sceFont.
    FontDirectory: string;
    function Find(Cls: TPSPServiceClass): TPSPService;
  end;

  TPSPService = class
  protected
    FSystem: TPSPSystem;
    FKernel: TPSPKernel;
    FHLE: TPSPHLE;
    FMemory: TPSPMemory;
  public
    constructor Create(System: TPSPSystem); virtual;
    procedure Reset; virtual;
    procedure Register; virtual; abstract;
    procedure OnEvent(Event: TPSPEvent); virtual;
    // Audio sources mix into the console's output (stereo, 44.1 kHz).
    procedure Mix(Buffer: PSmallInt; Frames: Integer); virtual;
    property System: TPSPSystem read FSystem;
  end;

procedure RegisterPSPService(Cls: TPSPServiceClass);

function PSPServiceClasses: TArray<TPSPServiceClass>;

implementation

var
  GServices: TArray<TPSPServiceClass>;

procedure RegisterPSPService(Cls: TPSPServiceClass);
begin
  for var C in GServices do
    if C = Cls then
      Exit;
  GServices := GServices + [Cls];
end;

function PSPServiceClasses: TArray<TPSPServiceClass>;
begin
  Result := GServices;
end;

function TPSPSystem.Find(Cls: TPSPServiceClass): TPSPService;
begin
  for var S in Services do
    if S is Cls then
      Exit(S);
  Result := nil;
end;

constructor TPSPService.Create(System: TPSPSystem);
begin
  inherited Create;
  FSystem := System;
  FKernel := System.Kernel;
  FHLE := System.HLE;
  FMemory := System.Memory;
end;

procedure TPSPService.Reset;
begin
end;

procedure TPSPService.OnEvent(Event: TPSPEvent);
begin
end;

procedure TPSPService.Mix(Buffer: PSmallInt; Frames: Integer);
begin
end;

end.

