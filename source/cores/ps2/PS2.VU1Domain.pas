unit PS2.VU1Domain;

// The VU1 domain: DMA channels 1 (VIF1) and 2 (GIF), VIF1, VU1 and the GIF
// with the GS it feeds. Its events run at their own due time (EnterEvent),
// not at the EE's next block boundary; the rest of the machine reaches it only
// between Enter and Leave, at the EE time, after the domain's events due by
// then (OnCatchUp). Its devices take the time from Now. Checked builds (or
// PS2_DOMAIN_CHECK) stop where a domain routine is reached from outside or
// the domain time would go back.
// Inside, the host SSE control word is DomainControlWord whatever the caller
// had (the GS takes its rounding from it): the domain's work does not depend
// on where it was caught up.
{$IFDEF PS2_CHECKED}
  {$Q+}
  {$R+}
{$ELSE}
  {$O+}
  {$Q-}
  {$R-}
{$ENDIF}

interface

uses
  System.SysUtils, PS2.Scheduler;

const
  // MXCSR inside the domain: all exceptions masked, rounding to nearest.
  DomainControlWord = $1F80;

type
  EPS2DomainAccess = class(Exception);

  // What an access from outside reaches: the domain itself, only the GS it
  // feeds, or registers the EE side keeps while the domain runs ahead
  // (D_STAT, D_PCR, D_SQWC, D_RBSR, D_RBOR, D_STADR, the other channels').
  TPS2DomainEntry = (deDomain, deGS, deLocal);

  // Running ahead: one of the domain's registers as the domain had it at the
  // EE time (False: not known, the EE takes the domain back).
  TPS2DomainRead = function(Address: Cardinal; out Value: UInt64): Boolean of object;
  // Running ahead: whether VU1 was busy at the EE time (False: not known).

  TPS2DomainBusy = function(out Busy: Boolean): Boolean of object;

// Values the EE and the VU1 thread hand each other. On x64 aligned loads and
// stores are atomic and keep their order (loads among loads, stores among
// stores), and as calls the compiler keeps them where they are; elsewhere
// they are interlocked.
function LoadShared(var Target: Int64): Int64; overload;

function LoadShared(var Target: Integer): Integer; overload;

procedure StoreShared(var Target: Int64; Value: Int64); overload;

procedure StoreShared(var Target: Integer; Value: Integer); overload;
// Whether Size bytes (a multiple of 16) at A and B are the same.

function SameQuads(A, B: Pointer; Size: NativeInt): Boolean;
// One more round of a wait for the other thread (Rounds: those so far): it
// spins, then gives up its time slice, then sleeps (a thread whose ring
// stays full while the emulator is paused does not keep a core).

procedure WaitRound(var Rounds: Integer);

type
  TPS2VU1Domain = class
  private
    FScheduler: TPS2Scheduler;
    FDepth: Integer;
    FOnCatchUp: TProc<Int64>;
    FOnLeave: TProc;
    FOnStopAhead: TProc;
    FSavedControl: Cardinal;
    procedure EnterControl;
{$IF DEFINED(PS2_CHECKED) OR DEFINED(PS2_DOMAIN_CHECK)}
    procedure Outside;
    procedure Backwards;
{$ENDIF}
  public
    // The time of the access or event the domain handles.
    Now: Int64;
    // Experimental: the domain runs ahead of the EE on its own thread (its
    // depth and time are that thread's then); Replaying: the EE side does
    // its events again as they ran ahead.
    Ahead, Replaying: Boolean;
    // Running ahead: the EE side's reads of the domain's registers and of
    // VU1's busy window.
    OnAheadRead: TPS2DomainRead;
    OnAheadBusy: TPS2DomainBusy;
    constructor Create(Scheduler: TPS2Scheduler);
    procedure Reset;
    // An access from outside at the EE time; nested calls stay inside. Both
    // do nothing on a nil domain (devices made without a console).
    procedure Enter;
    // An access of the given kind: running ahead, only one into the domain
    // itself enters it (False: nothing entered, no Leave).
    function EnterKind(Kind: TPS2DomainEntry): Boolean;
    // A domain event due at At (its handler runs at that time).
    procedure EnterEvent(At: Int64);
    // A snapshot load replaces the domain's state (and time): nothing to
    // catch up.
    procedure EnterRestore;
    procedure Leave;
    // Checked builds: the caller runs inside the domain (or has none).
    procedure Check; inline;
    property Depth: Integer read FDepth;
    property SavedHostWord: Cardinal read FSavedControl;
    // Runs the domain's events due by the given time.
    property OnCatchUp: TProc<Int64> read FOnCatchUp write FOnCatchUp;
    // The domain is left (its events may now be due earlier).
    property OnLeave: TProc read FOnLeave write FOnLeave;
    // An access into the domain while it runs ahead: the EE takes it back.
    property OnStopAhead: TProc read FOnStopAhead write FOnStopAhead;
  end;

implementation

uses
  System.Classes, System.SyncObjs;

procedure WaitRound(var Rounds: Integer);
begin
  if Rounds < 4000 then
  begin
    Inc(Rounds);
    YieldProcessor;
  end
  else if Rounds < 24000 then
  begin
    Inc(Rounds);
    TThread.Yield;
  end
  else
    TThread.Sleep(1);
end;

{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
function LoadShared(var Target: Int64): Int64;
asm
        .       NOFRAME
        mov     rax, [rcx]
end;

function LoadShared(var Target: Integer): Integer;
asm
        .       NOFRAME
        mov     eax, [rcx]
end;

procedure StoreShared(var Target: Int64; Value: Int64);
asm
        .       NOFRAME
        mov     [rcx], rdx
end;

procedure StoreShared(var Target: Integer; Value: Integer);
asm
        .       NOFRAME
        mov     [rcx], edx
end;
{$ELSE}

function LoadShared(var Target: Int64): Int64;
begin
  Result := TInterlocked.Read(Target);
end;

function LoadShared(var Target: Integer): Integer;
begin
  Result := TInterlocked.CompareExchange(Target, 0, 0);
end;

procedure StoreShared(var Target: Int64; Value: Int64);
begin
  TInterlocked.Exchange(Target, Value);
end;

procedure StoreShared(var Target: Integer; Value: Integer);
begin
  TInterlocked.Exchange(Target, Value);
end;
{$ENDIF}

{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}

function SameQuads(A, B: Pointer; Size: NativeInt): Boolean;
asm
        .       NOFRAME
        XOR     eax, eax

@Blocks:
        cmp     r8, 64
        jb      @Quads
        movdqu  xmm0, [rcx]
        movdqu  xmm1, [rdx]
        pcmpeqb xmm0, xmm1
        movdqu  xmm1, [rcx + 16]
        movdqu  xmm2, [rdx + 16]
        pcmpeqb xmm1, xmm2
        pand    xmm0, xmm1
        movdqu  xmm1, [rcx + 32]
        movdqu  xmm2, [rdx + 32]
        pcmpeqb xmm1, xmm2
        pand    xmm0, xmm1
        movdqu  xmm1, [rcx + 48]
        movdqu  xmm2, [rdx + 48]
        pcmpeqb xmm1, xmm2
        pand    xmm0, xmm1
        pmovmskb r9d, xmm0
        cmp     r9d, $FFFF
        jne     @Done
        add     rcx, 64
        add     rdx, 64
        sub     r8, 64
        jmp     @Blocks

@Quads:
        test    r8, r8
        jz      @Same
        movdqu  xmm0, [rcx]
        movdqu  xmm1, [rdx]
        pcmpeqb xmm0, xmm1
        pmovmskb r9d, xmm0
        cmp     r9d, $FFFF
        jne     @Done
        add     rcx, 16
        add     rdx, 16
        sub     r8, 16
        jmp     @Quads

@Same:
        mov     eax, 1

@Done:
end;
{$ELSE}

function SameQuads(A, B: Pointer; Size: NativeInt): Boolean;
begin
  Result := CompareMem(A, B, Size);
end;
{$ENDIF}

{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
// This thread's MXCSR (with its status flags: the caller gets them back).

function ControlWord: Cardinal;
asm
        .       NOFRAME
        stmxcsr [rsp + 8]
        mov     eax, [rsp + 8]
end;

// Loads Value into this thread's MXCSR only (not the run-time library's
// DefaultMXCSR, which other threads load).
procedure LoadControlWord(Value: Cardinal);
asm
        .       NOFRAME
        mov     [rsp + 8], ecx
        ldmxcsr [rsp + 8]
end;
{$ELSE}

function ControlWord: Cardinal;
begin
  Result := 0;
end;

procedure LoadControlWord(Value: Cardinal);
begin
end;
{$ENDIF}

constructor TPS2VU1Domain.Create(Scheduler: TPS2Scheduler);
begin
  inherited Create;
  FScheduler := Scheduler;
  Reset;
end;

procedure TPS2VU1Domain.Reset;
begin
  FDepth := 0;
  Now := 0;
end;

procedure TPS2VU1Domain.Enter;
begin
  if Self = nil then
    Exit;
  if Ahead and not Replaying and Assigned(FOnStopAhead) then
    FOnStopAhead();
  if FDepth = 0 then
  begin
    if Assigned(FOnCatchUp) then
      FOnCatchUp(FScheduler.Now);
{$IF DEFINED(PS2_CHECKED) OR DEFINED(PS2_DOMAIN_CHECK)}
    if FScheduler.Now < Now then
      Backwards;
{$ENDIF}
    Now := FScheduler.Now;
    EnterControl;
  end;
  Inc(FDepth);
end;

function TPS2VU1Domain.EnterKind(Kind: TPS2DomainEntry): Boolean;
begin
  Result := (Self <> nil) and (not Ahead or (Kind = deDomain));
  if Result then
    Enter;
end;

procedure TPS2VU1Domain.EnterControl;
begin
  FSavedControl := ControlWord;
  LoadControlWord(DomainControlWord);
end;

procedure TPS2VU1Domain.EnterEvent(At: Int64);
begin
  if FDepth = 0 then
  begin
{$IF DEFINED(PS2_CHECKED) OR DEFINED(PS2_DOMAIN_CHECK)}
    if At < Now then
      Backwards;
{$ENDIF}
    Now := At;
    EnterControl;
  end;
  Inc(FDepth);
end;

procedure TPS2VU1Domain.EnterRestore;
begin
  if FDepth = 0 then
    EnterControl;
  Inc(FDepth);
end;

procedure TPS2VU1Domain.Leave;
begin
  if Self = nil then
    Exit;
  Dec(FDepth);
  if FDepth = 0 then
  begin
    LoadControlWord(FSavedControl);
    if Assigned(FOnLeave) then
      FOnLeave();
  end;
end;

{$IF DEFINED(PS2_CHECKED) OR DEFINED(PS2_DOMAIN_CHECK)}
procedure TPS2VU1Domain.Outside;
begin
  raise EPS2DomainAccess.Create('PS2 VU1 domain reached from outside');
end;

procedure TPS2VU1Domain.Backwards;
begin
  raise EPS2DomainAccess.Create('PS2 VU1 domain time went back');
end;
{$ENDIF}

procedure TPS2VU1Domain.Check;
begin
{$IF DEFINED(PS2_CHECKED) OR DEFINED(PS2_DOMAIN_CHECK)}
  if (Self <> nil) and (FDepth = 0) then
    Outside;
{$ENDIF}
end;

end.

