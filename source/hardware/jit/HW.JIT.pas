unit HW.JIT;

// Code generated at run time, for any core (the N64 CPU's blocks first). A
// core writes it in TJitAsm's few operations, over registers by role
// (TJitReg) and simple operands (TJitOp), and knows no host instruction. A
// backend turns them into one host's instructions and calling convention in
// executable memory, with unwind data so exceptions pass through the code:
// x64 instructions (TJitAsmX64) with the Win64 convention (TJitAsmWin64) or
// Linux's System V one (TJitAsmSysV64), AArch64 instructions with AAPCS64
// (TJitAsmA64) on Android (TJitAsmAndroid64). Other targets compile the unit
// and make no code (JitSupported False, CreateJitAsm nil).
//
// The model (CreateJitModel, every target) writes no machine code: it keeps
// the operations and runs them itself, in Pascal (Invoke). It is what each
// operation means, for the tests: a backend's code must do what the model
// does, and a core's code run by the model what the core's interpreter does.

interface

{$Q-}{$R-}

uses
  System.SysUtils;

const
  JitSupported = {$IF (DEFINED(CPUX64) AND (DEFINED(MSWINDOWS) OR DEFINED(LINUX))) OR
    (DEFINED(CPUARM64) AND DEFINED(ANDROID))}True{$ELSE}False{$ENDIF};

type
  // Registers by role. The fixed ones keep their values across calls: Self
  // and Ctx (a function's two arguments, Enter), S0..S3 (the core's own), S4
  // where the backend has one more (Has). The scratch ones T0..T6 do not; a
  // call returns its result in T0.
  TJitReg = (jrSelf, jrCtx, jrS0, jrS1, jrS2, jrS3, jrT0, jrT1, jrT2, jrT3, jrT4, jrT5, jrT6, jrS4);

  // An operation's width: 8 and 32 bits zero-extend into a register.
  TJitWidth = (jw8, jw32, jw64);

  // An operand: a register, a constant, memory at Reg + Disp, or that address
  // as a value. At most one operand of an operation is in memory; constants
  // fit 32 bits (sign-extended to 64) but in Move to a register.
  TJitOpKind = (okReg, okImm, okMem, okAddr);
  TJitOp = record
    Kind: TJitOpKind;
    Reg: TJitReg;
    Disp: Integer;
    Imm: Int64;
  end;

  TJitAlu = (jaAdd, jaSub, jaAnd, jaOr, jaXor);
  // Left, right logical, right arithmetic (8 bits: as 32).
  TJitShift = (jsShl, jsShr, jsSar);
  // After Branch's comparison of A with B: signed jcLt..jcGe, unsigned
  // jcBelow..jcAboveEq. After BranchTest of A and B: jcEq none of the bits,
  // jcNe some.
  TJitCond = (jcEq, jcNe, jcLt, jcLe, jcGt, jcGe, jcBelow, jcBelowEq, jcAbove, jcAboveEq);

  TJitLabel = Integer;

  // Code in one buffer of executable memory, written by the operations
  // below; a backend implements the abstract ones. Offsets are from the
  // buffer's start.
  TJitAsm = class abstract
  private
    FBase: PByte;
    FSize, FUsed, FCodeStart, FFlushed: NativeInt;
    // Labels: where each is (-1: not yet), and the jumps to ones not yet
    // bound (their fields). Kept from function to function, so that writing
    // code calls no memory manager once they are long enough.
    FLabelAt: TArray<NativeInt>;
    FFixLabel: TArray<TJitLabel>;
    FFixField: TArray<NativeInt>;
    FLabelCount, FFixCount: Integer;
    procedure Fix(Field: NativeInt; L: TJitLabel);
  protected
    // Room's estimates times this (the model's operations take more bytes
    // than instructions).
    FRoomScale: Integer;
    procedure Need(Bytes: NativeInt); inline;
    procedure Emit(const Bytes: array of Byte);
    procedure D(V: Cardinal);
    procedure Q(V: UInt64);
    // The memory: Size bytes, code from CodeStart on.
    function Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte; virtual; abstract;
    procedure Release(Base: PByte); virtual; abstract;
    procedure FlushCode(P: PByte; Len: NativeInt); virtual; abstract;
    // A comparison of A with B, a test of A and B; a jump (conditional on
    // the flags they leave) with a field for its target, which the result
    // is; that field's target, set and read.
    procedure EmitCompare(W: TJitWidth; const A, B: TJitOp); virtual; abstract;
    procedure EmitTest(W: TJitWidth; const A, B: TJitOp); virtual; abstract;
    function EmitJumpIf(Cond: TJitCond): NativeInt; virtual; abstract;
    function EmitJump: NativeInt; virtual; abstract;
    procedure PatchJump(Field, Target: NativeInt); virtual; abstract;
    function JumpTargetOf(Field: NativeInt): NativeInt; virtual; abstract;
    // A jump (conditional on the flags) to code written before.
    procedure EmitJumpIfTo(Cond: TJitCond; Target: NativeInt); virtual;
    // BranchTest's test and jump (its field), where a backend has one
    // instruction for some.
    function EmitTestJump(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp): NativeInt; virtual;
    // Whether the backend has a register for S4.
    function HasS4: Boolean; virtual;
  public
    constructor Create(Size: NativeInt);
    destructor Destroy; override;
    // Drops all code.
    procedure Reset;
    function Room(Bytes: NativeInt): Boolean; inline;
    function Here: PByte; inline;
    function Offset: NativeInt; inline;
    procedure Align(N: Integer);

    // Dst := Src.
    procedure Move(W: TJitWidth; const Dst, Src: TJitOp); virtual; abstract;
    // Dst := Dst op Src.
    procedure Alu(Op: TJitAlu; W: TJitWidth; const Dst, Src: TJitOp); virtual; abstract;
    procedure Shift(Op: TJitShift; W: TJitWidth; Dst: TJitReg; Count: Integer); virtual; abstract;
    // Dst := its low W bits sign-extended to 64.
    procedure SignExtend(W: TJitWidth; Dst: TJitReg); virtual; abstract;
    // A routine with up to four arguments (pointer-sized; memory ones read as
    // 64 bits); its result in T0, the scratch registers changed.
    procedure Call(Routine: Pointer; const Args: array of TJitOp); virtual; abstract;
    // As Call, the routine's address read from memory operand Routine (its
    // register not one the arguments change).
    procedure CallAt(const Routine: TJitOp; const Args: array of TJitOp); virtual; abstract;
    // A function's start: the fixed registers saved, Self and Ctx from its
    // two arguments. Its end: Value as its result, the fixed registers as
    // they were, back to its caller.
    procedure Enter; virtual; abstract;
    procedure Leave(const Value: TJitOp); virtual; abstract;
    // The start of a function of four arguments shared by many: as Enter,
    // then its fourth argument in T1 and on to the address in its third
    // (code that ends with Leave).
    procedure EnterJump; virtual; abstract;
    // To the address in Target.
    procedure JumpIndirect(const Target: TJitOp); virtual; abstract;
    // Whether role R has a register here.
    function Has(R: TJitReg): Boolean;
    // A hint before any code is written: Self's fields from Disp on are used
    // often (a backend with short displacements keeps a register there).
    procedure AddWindow(Disp: Integer); virtual;

    // Labels within the function being written; ForgetLabels before the next
    // (all of them bound by then).
    function NewLabel: TJitLabel;
    procedure Bind(L: TJitLabel);
    procedure ForgetLabels;
    procedure Branch(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; L: TJitLabel);
    procedure BranchTest(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; L: TJitLabel);
    procedure Jump(L: TJitLabel);
    // To code written before (its offset).
    procedure BranchTo(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; Target: NativeInt);
    procedure JumpTo(Target: NativeInt);
    // A jump to code written before that can be pointed elsewhere later
    // (Redirect): its site.
    function JumpSite(Target: NativeInt): NativeInt;
    function SiteTarget(Site: NativeInt): NativeInt;
    procedure Redirect(Site, Target: NativeInt);
    // The code written since the last Flush made ready to run.
    procedure Flush;
    // Runs the function at Code (written with Enter or EnterJump) with four
    // pointer-sized arguments (unused ones ignored): its result.
    function Invoke(Code: Pointer; A0, A1, A2, A3: NativeUInt): NativeInt; virtual;
    property Size: NativeInt read FSize;
    property Base: PByte read FBase;
  end;

function JReg(Reg: TJitReg): TJitOp; inline;
function JImm(Value: Int64): TJitOp; inline;
function JMem(Base: TJitReg; Disp: Integer): TJitOp; inline;
function JAddr(Base: TJitReg; Disp: Integer): TJitOp; inline;

const
  JSelf: TJitOp = (Kind: okReg; Reg: jrSelf);
  JCtx: TJitOp = (Kind: okReg; Reg: jrCtx);
  JS0: TJitOp = (Kind: okReg; Reg: jrS0);
  JS1: TJitOp = (Kind: okReg; Reg: jrS1);
  JS2: TJitOp = (Kind: okReg; Reg: jrS2);
  JS3: TJitOp = (Kind: okReg; Reg: jrS3);
  JS4: TJitOp = (Kind: okReg; Reg: jrS4);
  JT0: TJitOp = (Kind: okReg; Reg: jrT0);
  JT1: TJitOp = (Kind: okReg; Reg: jrT1);
  JT2: TJitOp = (Kind: okReg; Reg: jrT2);
  JT3: TJitOp = (Kind: okReg; Reg: jrT3);
  JT4: TJitOp = (Kind: okReg; Reg: jrT4);
  JT5: TJitOp = (Kind: okReg; Reg: jrT5);
  JT6: TJitOp = (Kind: okReg; Reg: jrT6);

// This target's code generator with Size bytes of code (nil: none here).
function CreateJitAsm(Size: NativeInt): TJitAsm;
// The model (every target), with Size bytes for its operations.
function CreateJitModel(Size: NativeInt): TJitAsm;

implementation

{$IF JitSupported}
uses
  {$IFDEF MSWINDOWS}Winapi.Windows{$ELSE}Posix.SysMman{$ENDIF};
{$ENDIF}

function JReg(Reg: TJitReg): TJitOp;
begin
  Result := Default(TJitOp);
  Result.Kind := okReg;
  Result.Reg := Reg;
end;

function JImm(Value: Int64): TJitOp;
begin
  Result := Default(TJitOp);
  Result.Kind := okImm;
  Result.Imm := Value;
end;

function JMem(Base: TJitReg; Disp: Integer): TJitOp;
begin
  Result := Default(TJitOp);
  Result.Kind := okMem;
  Result.Reg := Base;
  Result.Disp := Disp;
end;

function JAddr(Base: TJitReg; Disp: Integer): TJitOp;
begin
  Result := Default(TJitOp);
  Result.Kind := okAddr;
  Result.Reg := Base;
  Result.Disp := Disp;
end;

{ TJitAsm }

constructor TJitAsm.Create(Size: NativeInt);
begin
  inherited Create;
  FRoomScale := 1;
  FSize := Size;
  FBase := Allocate(Size, FCodeStart);
  Reset;
end;

destructor TJitAsm.Destroy;
begin
  if FBase <> nil then
    Release(FBase);
  inherited;
end;

procedure TJitAsm.Reset;
begin
  FUsed := FCodeStart;
  FFlushed := FCodeStart;
  FLabelCount := 0;
  FFixCount := 0;
end;

procedure TJitAsm.EmitJumpIfTo(Cond: TJitCond; Target: NativeInt);
begin
  PatchJump(EmitJumpIf(Cond), Target);
end;

function TJitAsm.EmitTestJump(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp): NativeInt;
begin
  EmitTest(W, A, B);
  Result := EmitJumpIf(Cond);
end;

function TJitAsm.HasS4: Boolean;
begin
  Result := False;
end;

function TJitAsm.Has(R: TJitReg): Boolean;
begin
  Result := (R <> jrS4) or HasS4;
end;

procedure TJitAsm.AddWindow(Disp: Integer);
begin
end;

function TJitAsm.Room(Bytes: NativeInt): Boolean;
begin
  Result := (FBase <> nil) and (FUsed + Bytes * FRoomScale <= FSize);
end;

procedure TJitAsm.Need(Bytes: NativeInt);
begin
  if FUsed + Bytes > FSize then
    raise EInvalidOpException.Create('JIT buffer overflow');
end;

function TJitAsm.Here: PByte;
begin
  Result := FBase + FUsed;
end;

function TJitAsm.Offset: NativeInt;
begin
  Result := FUsed;
end;

procedure TJitAsm.Align(N: Integer);
begin
  // (Filled with a breakpoint, never run.)
  while (FUsed and (N - 1)) <> 0 do
    Emit([$CC]);
end;

procedure TJitAsm.Emit(const Bytes: array of Byte);
begin
  Need(Length(Bytes));
  System.Move(Bytes[0], FBase[FUsed], Length(Bytes));
  Inc(FUsed, Length(Bytes));
end;

procedure TJitAsm.D(V: Cardinal);
begin
  Need(4);
  PCardinal(@FBase[FUsed])^ := V;
  Inc(FUsed, 4);
end;

procedure TJitAsm.Q(V: UInt64);
begin
  Need(8);
  PUInt64(@FBase[FUsed])^ := V;
  Inc(FUsed, 8);
end;

function TJitAsm.NewLabel: TJitLabel;
begin
  if FLabelCount = Length(FLabelAt) then
    SetLength(FLabelAt, FLabelCount * 2 + 64);
  FLabelAt[FLabelCount] := -1;
  Result := FLabelCount;
  Inc(FLabelCount);
end;

procedure TJitAsm.Fix(Field: NativeInt; L: TJitLabel);
begin
  if FLabelAt[L] >= 0 then
  begin
    PatchJump(Field, FLabelAt[L]);
    Exit;
  end;
  if FFixCount = Length(FFixField) then
  begin
    SetLength(FFixField, FFixCount * 2 + 64);
    SetLength(FFixLabel, FFixCount * 2 + 64);
  end;
  FFixField[FFixCount] := Field;
  FFixLabel[FFixCount] := L;
  Inc(FFixCount);
end;

procedure TJitAsm.Bind(L: TJitLabel);
begin
  FLabelAt[L] := FUsed;
  var K := 0;
  while K < FFixCount do
    if FFixLabel[K] = L then
    begin
      PatchJump(FFixField[K], FUsed);
      Dec(FFixCount);
      FFixField[K] := FFixField[FFixCount];
      FFixLabel[K] := FFixLabel[FFixCount];
    end
    else
      Inc(K);
end;

procedure TJitAsm.ForgetLabels;
begin
  if FFixCount <> 0 then
    raise EInvalidOpException.Create('JIT: a jump to a label not bound');
  FLabelCount := 0;
end;

procedure TJitAsm.Branch(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; L: TJitLabel);
begin
  EmitCompare(W, A, B);
  Fix(EmitJumpIf(Cond), L);
end;

procedure TJitAsm.BranchTest(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; L: TJitLabel);
begin
  Fix(EmitTestJump(Cond, W, A, B), L);
end;

procedure TJitAsm.Jump(L: TJitLabel);
begin
  Fix(EmitJump, L);
end;

procedure TJitAsm.BranchTo(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; Target: NativeInt);
begin
  EmitCompare(W, A, B);
  EmitJumpIfTo(Cond, Target);
end;

procedure TJitAsm.JumpTo(Target: NativeInt);
begin
  PatchJump(EmitJump, Target);
end;

function TJitAsm.JumpSite(Target: NativeInt): NativeInt;
begin
  Result := EmitJump;
  PatchJump(Result, Target);
end;

function TJitAsm.SiteTarget(Site: NativeInt): NativeInt;
begin
  Result := JumpTargetOf(Site);
end;

procedure TJitAsm.Redirect(Site, Target: NativeInt);
begin
  // (Code that may be running: the field is written at once.)
  PatchJump(Site, Target);
  FlushCode(FBase + Site, 4);
end;

procedure TJitAsm.Flush;
begin
  if FUsed > FFlushed then
    FlushCode(FBase + FFlushed, FUsed - FFlushed);
  FFlushed := FUsed;
end;

function TJitAsm.Invoke(Code: Pointer; A0, A1, A2, A3: NativeUInt): NativeInt;
type
  TJitFunction = function(A0, A1, A2, A3: NativeUInt): NativeInt;
begin
  Result := TJitFunction(Code)(A0, A1, A2, A3);
end;

{ x64 }

const
  rAX = 0; rCX = 1; rDX = 2; rBX = 3; rSP = 4; rBP = 5; rSI = 6; rDI = 7;
  r8 = 8; r9 = 9; r10 = 10; r11 = 11; r12 = 12; r13 = 13; r14 = 14; r15 = 15;

type
  // An operand with x64 register numbers.
  TX64Op = record
    Kind: TJitOpKind;
    Reg: Integer;
    Disp: Integer;
    Imm: Int64;
  end;

  // TJitAsm's operations as x64 instructions. The calling convention (each
  // role's register and the arguments', a function's frame and its unwind
  // data) and the memory are a subclass's.
  TJitAsmX64 = class abstract(TJitAsm)
  protected
    FPhys: array[TJitReg] of Byte;
    FArgs: array[0..3] of Byte;
    function X(const Op: TJitOp): TX64Op;
    procedure ModRM(W64: Boolean; const Opcode: array of Byte; RegField: Integer; ByteReg: Boolean; const RM: TX64Op;
      ByteRM: Boolean);
    procedure LoadImm(W: TJitWidth; Reg: Integer; Value: Int64);
    procedure MoveX(W: TJitWidth; const Dst, Src: TX64Op);
    procedure MoveArgs(const Args: array of TJitOp);
    procedure EmitCompare(W: TJitWidth; const A, B: TJitOp); override;
    procedure EmitTest(W: TJitWidth; const A, B: TJitOp); override;
    function EmitJumpIf(Cond: TJitCond): NativeInt; override;
    function EmitJump: NativeInt; override;
    procedure PatchJump(Field, Target: NativeInt); override;
    function JumpTargetOf(Field: NativeInt): NativeInt; override;
  public
    procedure Move(W: TJitWidth; const Dst, Src: TJitOp); override;
    procedure Alu(Op: TJitAlu; W: TJitWidth; const Dst, Src: TJitOp); override;
    procedure Shift(Op: TJitShift; W: TJitWidth; Dst: TJitReg; Count: Integer); override;
    procedure SignExtend(W: TJitWidth; Dst: TJitReg); override;
    procedure Call(Routine: Pointer; const Args: array of TJitOp); override;
    procedure CallAt(const Routine: TJitOp; const Args: array of TJitOp); override;
    procedure JumpIndirect(const Target: TJitOp); override;
    procedure EnterJump; override;
  end;

const
  // TJitAlu: the /digit of op r/m, imm32 (81 /digit), and op r/m, r (op r,
  // r/m is 2 more; the byte forms 1 less).
  AluExt: array[TJitAlu] of Byte = (0, 5, 4, 1, 6);
  AluToRM: array[TJitAlu] of Byte = ($01, $29, $21, $09, $31);
  CondCode: array[TJitCond] of Byte = ($4, $5, $C, $E, $F, $D, $2, $6, $7, $3);

function X64Reg(Reg: Integer): TX64Op;
begin
  Result := Default(TX64Op);
  Result.Kind := okReg;
  Result.Reg := Reg;
end;

function Imm32(Value: Int64; W: TJitWidth): Cardinal;
begin
  // As a 32-bit immediate: sign-extended to 64 bits, or for a 32-bit
  // operation any 32-bit value.
  if (Value >= -Int64($80000000)) and (Value <= $7FFFFFFF) then
    Exit(Cardinal(Integer(Value)));
  if (W <> jw64) and (Value >= 0) and (Value <= $FFFFFFFF) then
    Exit(Cardinal(Value));
  raise EInvalidOpException.Create('JIT: a constant out of range');
end;

function TJitAsmX64.X(const Op: TJitOp): TX64Op;
begin
  if (Op.Kind <> okImm) and (Op.Reg = jrS4) then
    raise EInvalidOpException.Create('JIT: no S4 here');
  Result.Kind := Op.Kind;
  Result.Reg := FPhys[Op.Reg];
  Result.Disp := Op.Disp;
  Result.Imm := Op.Imm;
end;

procedure TJitAsmX64.ModRM(W64: Boolean; const Opcode: array of Byte; RegField: Integer; ByteReg: Boolean;
  const RM: TX64Op; ByteRM: Boolean);
begin
  // REX: W for 64 bits, R and B for registers 8..15, a plain one for the byte
  // registers SPL..DIL (ByteReg, ByteRM: the operand is a byte register).
  // Memory: [base + disp32]; no base needs a SIB byte (RSP, R12).
  var Rex: Byte := $40;
  if W64 then
    Rex := Rex or 8;
  if RegField >= 8 then
    Rex := Rex or 4;
  if RM.Reg >= 8 then
    Rex := Rex or 1;
  var Plain := (ByteReg and (RegField in [4..7])) or (ByteRM and (RM.Kind = okReg) and (RM.Reg in [4..7]));
  if (Rex <> $40) or Plain then
    Emit([Rex]);
  Emit(Opcode);
  if RM.Kind = okReg then
    Emit([$C0 or ((RegField and 7) shl 3) or (RM.Reg and 7)])
  else
  begin
    if (RM.Reg and 7) = rSP then
      raise EInvalidOpException.Create('JIT: no such base register');
    Emit([$80 or ((RegField and 7) shl 3) or (RM.Reg and 7)]);
    D(Cardinal(RM.Disp));
  end;
end;

procedure TJitAsmX64.LoadImm(W: TJitWidth; Reg: Integer; Value: Int64);
begin
  if (W <> jw64) or ((Value >= 0) and (Value <= $FFFFFFFF)) then
  begin
    // mov r32, imm32 (zero-extends)
    if Reg >= 8 then
      Emit([$41]);
    Emit([$B8 + (Reg and 7)]);
    D(Cardinal(Value));
  end
  else if (Value < 0) and (Value >= -Int64($80000000)) then
  begin
    // mov r/m64, imm32 (sign-extends)
    ModRM(True, [$C7], 0, False, X64Reg(Reg), False);
    D(Cardinal(Integer(Value)));
  end
  else
  begin
    var Rex: Byte := $48;
    if Reg >= 8 then
      Rex := Rex or 1;
    Emit([Rex, $B8 + (Reg and 7)]);
    Q(UInt64(Value));
  end;
end;

procedure TJitAsmX64.MoveX(W: TJitWidth; const Dst, Src: TX64Op);
begin
  if Dst.Kind = okReg then
    case Src.Kind of
      okReg:
        if W = jw8 then
          ModRM(False, [$0F, $B6], Dst.Reg, False, Src, True)           // movzx r32, r8
        else if (W = jw32) or (Dst.Reg <> Src.Reg) then
          ModRM(W = jw64, [$89], Src.Reg, False, Dst, False);
      okImm:
        LoadImm(W, Dst.Reg, Src.Imm);
      okMem:
        if W = jw8 then
          ModRM(False, [$0F, $B6], Dst.Reg, False, Src, False)          // movzx r32, byte [m]
        else
          ModRM(W = jw64, [$8B], Dst.Reg, False, Src, False);
      okAddr:
        ModRM(True, [$8D], Dst.Reg, False, Src, False);                // lea
    end
  else if (Dst.Kind = okMem) and (Src.Kind = okReg) then
  begin
    if W = jw8 then
      ModRM(False, [$88], Src.Reg, True, Dst, False)
    else
      ModRM(W = jw64, [$89], Src.Reg, False, Dst, False);
  end
  else if (Dst.Kind = okMem) and (Src.Kind = okImm) then
  begin
    if W = jw8 then
    begin
      ModRM(False, [$C6], 0, False, Dst, False);
      Emit([Byte(Src.Imm)]);
    end
    else
    begin
      ModRM(W = jw64, [$C7], 0, False, Dst, False);
      D(Imm32(Src.Imm, W));
    end;
  end
  else
    raise EInvalidOpException.Create('JIT: no such move');
end;

procedure TJitAsmX64.Move(W: TJitWidth; const Dst, Src: TJitOp);
begin
  MoveX(W, X(Dst), X(Src));
end;

procedure TJitAsmX64.Alu(Op: TJitAlu; W: TJitWidth; const Dst, Src: TJitOp);
begin
  var A := X(Dst);
  var B := X(Src);
  if B.Kind = okImm then
  begin
    if W = jw8 then
    begin
      ModRM(False, [$80], AluExt[Op], False, A, True);
      Emit([Byte(B.Imm)]);
    end
    else
    begin
      ModRM(W = jw64, [$81], AluExt[Op], False, A, False);
      D(Imm32(B.Imm, W));
    end;
  end
  else if (B.Kind = okReg) and (A.Kind in [okReg, okMem]) then
    ModRM(W = jw64, [AluToRM[Op] - Ord(W = jw8)], B.Reg, W = jw8, A, W = jw8)
  else if (A.Kind = okReg) and (B.Kind = okMem) then
    ModRM(W = jw64, [AluToRM[Op] + 2 - Ord(W = jw8)], A.Reg, W = jw8, B, False)
  else
    raise EInvalidOpException.Create('JIT: no such operation');
end;

procedure TJitAsmX64.Shift(Op: TJitShift; W: TJitWidth; Dst: TJitReg; Count: Integer);
const
  Ext: array[TJitShift] of Integer = (4, 5, 7);
begin
  // shl/shr/sar r, imm8 (C1 /4, /5, /7)
  ModRM(W = jw64, [$C1], Ext[Op], False, X(JReg(Dst)), False);
  Emit([Byte(Count)]);
end;

procedure TJitAsmX64.SignExtend(W: TJitWidth; Dst: TJitReg);
begin
  // movsxd r64, r32 (63); movsx r64, r8 (0F BE); nothing for 64 bits
  var R := X(JReg(Dst));
  case W of
    jw8:
      ModRM(True, [$0F, $BE], R.Reg, False, R, True);
    jw32:
      ModRM(True, [$63], R.Reg, False, R, False);
  end;
end;

procedure TJitAsmX64.EmitCompare(W: TJitWidth; const A, B: TJitOp);
begin
  // cmp (81 /7 or 80 /7 with a constant; 39 cmp r/m, r; 3B cmp r, r/m)
  var P := X(A);
  var R := X(B);
  if R.Kind = okImm then
  begin
    if W = jw8 then
    begin
      ModRM(False, [$80], 7, False, P, True);
      Emit([Byte(R.Imm)]);
    end
    else
    begin
      ModRM(W = jw64, [$81], 7, False, P, False);
      D(Imm32(R.Imm, W));
    end;
  end
  else if (R.Kind = okReg) and (P.Kind in [okReg, okMem]) then
    ModRM(W = jw64, [$39 - Ord(W = jw8)], R.Reg, W = jw8, P, W = jw8)
  else if (P.Kind = okReg) and (R.Kind = okMem) then
    ModRM(W = jw64, [$3B - Ord(W = jw8)], P.Reg, W = jw8, R, False)
  else
    raise EInvalidOpException.Create('JIT: no such comparison');
end;

procedure TJitAsmX64.EmitTest(W: TJitWidth; const A, B: TJitOp);
begin
  // test (A8 test al, imm8; F6 /0, F7 /0 with a constant; 84, 85 test r/m, r)
  var P := X(A);
  var R := X(B);
  if R.Kind = okImm then
  begin
    if W = jw8 then
    begin
      if (P.Kind = okReg) and (P.Reg = rAX) then
        Emit([$A8])
      else
        ModRM(False, [$F6], 0, False, P, True);
      Emit([Byte(R.Imm)]);
    end
    else
    begin
      ModRM(W = jw64, [$F7], 0, False, P, False);
      D(Imm32(R.Imm, W));
    end;
  end
  else if (R.Kind = okReg) and (P.Kind in [okReg, okMem]) then
    ModRM(W = jw64, [$85 - Ord(W = jw8)], R.Reg, W = jw8, P, W = jw8)
  else
    raise EInvalidOpException.Create('JIT: no such test');
end;

function TJitAsmX64.EmitJumpIf(Cond: TJitCond): NativeInt;
begin
  Emit([$0F, $80 or CondCode[Cond]]);                    // jcc rel32
  Result := Offset;
  D(0);
end;

function TJitAsmX64.EmitJump: NativeInt;
begin
  Emit([$E9]);                                           // jmp rel32
  Result := Offset;
  D(0);
end;

procedure TJitAsmX64.PatchJump(Field, Target: NativeInt);
begin
  PInteger(Base + Field)^ := Integer(Target - (Field + 4));
end;

function TJitAsmX64.JumpTargetOf(Field: NativeInt): NativeInt;
begin
  Result := Field + 4 + PInteger(Base + Field)^;
end;

procedure TJitAsmX64.MoveArgs(const Args: array of TJitOp);
var
  Src: array[0..3] of TX64Op;
  Pending: array[0..3] of Boolean;
begin
  // The arguments into their registers, each once no other still to be
  // moved reads its register (arguments that read each other's raise).
  if Length(Args) > Length(FArgs) then
    raise EInvalidOpException.Create('JIT: too many arguments');
  var Left := 0;
  for var K := 0 to High(Args) do
  begin
    Src[K] := X(Args[K]);
    Pending[K] := not ((Src[K].Kind = okReg) and (Src[K].Reg = FArgs[K]));
    if Pending[K] then
      Inc(Left);
  end;
  while Left > 0 do
  begin
    var Moved := False;
    for var K := 0 to High(Args) do
      if Pending[K] then
      begin
        var Blocked := False;
        for var M := 0 to High(Args) do
          if (M <> K) and Pending[M] and (Src[M].Kind <> okImm) and (Src[M].Reg = FArgs[K]) then
            Blocked := True;
        if not Blocked then
        begin
          MoveX(jw64, X64Reg(FArgs[K]), Src[K]);
          Pending[K] := False;
          Dec(Left);
          Moved := True;
        end;
      end;
    if not Moved then
      raise EInvalidOpException.Create('JIT: call arguments read each other');
  end;
end;

procedure TJitAsmX64.Call(Routine: Pointer; const Args: array of TJitOp);
begin
  MoveArgs(Args);
  LoadImm(jw64, rAX, Int64(NativeUInt(Routine)));
  Emit([$FF, $D0]);                                      // call rax
end;

procedure TJitAsmX64.CallAt(const Routine: TJitOp; const Args: array of TJitOp);
begin
  if Routine.Kind <> okMem then
    raise EInvalidOpException.Create('JIT: no such call');
  MoveArgs(Args);
  ModRM(False, [$FF], 2, False, X(Routine), False);      // call r/m64
end;

procedure TJitAsmX64.JumpIndirect(const Target: TJitOp);
begin
  ModRM(False, [$FF], 4, False, X(Target), False);       // jmp r/m64
end;

procedure TJitAsmX64.EnterJump;
begin
  Enter;
  if FArgs[3] <> FPhys[jrT1] then
    MoveX(jw64, X64Reg(FPhys[jrT1]), X64Reg(FArgs[3]));
  ModRM(False, [$FF], 4, False, X64Reg(FArgs[2]), False);
end;

{ ARM64 }

const
  // AArch64 registers x0..x30; 31 is SP or the zero register by instruction.
  // x16, x17 and x8 are the backend's own: an address or a call's target, a
  // value, a second operand. x25 is Self + 32 KB, for fields past 32 KB;
  // x27, x28 the windows asked for (AddWindow).
  aIP0 = 16;
  aIP1 = 17;
  aTmp = 8;
  aHigh = 25;
  aZR = 31;
  A64High = 32768;
  A64WinReg: array[0..1] of Integer = (27, 28);
  // TJitCond as AArch64 condition codes (the opposite: bit 0 flipped).
  A64Cond: array[TJitCond] of Cardinal = (0, 1, 11, 13, 12, 10, 3, 9, 8, 2);
  // TJitAlu: ADD, SUB, AND, ORR, EOR (shifted register, 32-bit; bit 31 for
  // 64), and AND, ORR, EOR with a bitmask constant.
  A64AluReg: array[TJitAlu] of Cardinal = ($0B000000, $4B000000, $0A000000, $2A000000, $4A000000);
  A64AluImm: array[TJitAlu] of Cardinal = (0, 0, $12000000, $32000000, $52000000);
  A64Bytes: array[TJitWidth] of Integer = (1, 4, 8);

type
  // TJitAsm's operations as AArch64 instructions with the AAPCS64
  // convention: arguments in x0..x3, the result in x0, x19..x28 kept by a
  // callee (Self x19, Ctx x20, S0..S3 x21..x24, S4 x26), x18 left alone (the
  // platform's); the scratch roles T0 in x0 (a call's result is there),
  // T1..T6 in x9..x14. Enter's frame: x29, x30, x19..x28 in 96 bytes below
  // the caller's SP. Calls are BL where the routine is within reach (128 MB).
  // The memory, the instruction cache and the unwind data are a subclass's.
  TJitAsmA64 = class abstract(TJitAsm)
  private
    // The windows: Self + FWinBase[K] in A64WinReg[K].
    FWinBase: array[0..1] of Integer;
    FWins: Integer;
  protected
    FPhys: array[TJitReg] of Byte;
    function HasS4: Boolean; override;
    procedure I(V: Cardinal); inline;
    procedure LoadImm(Is64: Boolean; Rd: Integer; Value: UInt64);
    procedure MovReg(Is64: Boolean; Rd, Rm: Integer);
    procedure AddImm(Is64: Boolean; Rd, Rn: Integer; Value: Int64);
    function Direct(var Base, Disp: Integer; Size: Integer): Boolean;
    procedure LoadStore(Store: Boolean; Size, Rt, Base, Disp: Integer);
    function Fetch(W: TJitWidth; const Op: TJitOp; Scratch: Integer): Integer;
    procedure AluReg(Op: TJitAlu; W: TJitWidth; Rd: Integer; const Src: TJitOp);
    procedure MoveArgs(const Args: array of TJitOp);
    procedure EmitCompare(W: TJitWidth; const A, B: TJitOp); override;
    procedure EmitTest(W: TJitWidth; const A, B: TJitOp); override;
    function EmitJumpIf(Cond: TJitCond): NativeInt; override;
    function EmitJump: NativeInt; override;
    procedure EmitJumpIfTo(Cond: TJitCond; Target: NativeInt); override;
    function EmitTestJump(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp): NativeInt; override;
    procedure PatchJump(Field, Target: NativeInt); override;
    function JumpTargetOf(Field: NativeInt): NativeInt; override;
  public
    constructor Create(Size: NativeInt);
    procedure Move(W: TJitWidth; const Dst, Src: TJitOp); override;
    procedure Alu(Op: TJitAlu; W: TJitWidth; const Dst, Src: TJitOp); override;
    procedure Shift(Op: TJitShift; W: TJitWidth; Dst: TJitReg; Count: Integer); override;
    procedure SignExtend(W: TJitWidth; Dst: TJitReg); override;
    procedure Call(Routine: Pointer; const Args: array of TJitOp); override;
    procedure CallAt(const Routine: TJitOp; const Args: array of TJitOp); override;
    procedure JumpIndirect(const Target: TJitOp); override;
    procedure AddWindow(Disp: Integer); override;
    procedure Enter; override;
    procedure Leave(const Value: TJitOp); override;
    procedure EnterJump; override;
  end;

function A64LogicalImm(Value: UInt64; Is64: Boolean; out Bits: Cardinal): Boolean;

  function IsMask(V: UInt64): Boolean;
  begin
    Result := (V <> 0) and (((V + 1) and V) = 0);
  end;

  function IsShiftedMask(V: UInt64): Boolean;
  begin
    Result := (V <> 0) and IsMask((V - 1) or V);
  end;

  function TrailingZeros(V: UInt64): Cardinal;
  begin
    Result := 0;
    while (Result < 64) and ((V and (UInt64(1) shl Result)) = 0) do
      Inc(Result);
  end;

  function TrailingOnes(V: UInt64): Cardinal;
  begin
    Result := TrailingZeros(not V);
  end;

  function LeadingOnes(V: UInt64): Cardinal;
  begin
    Result := 0;
    while (Result < 64) and ((V and (UInt64(1) shl (63 - Result))) <> 0) do
      Inc(Result);
  end;

begin
  // A logical instruction's bitmask constant (N:immr:imms in bits 22..10),
  // as LLVM's processLogicalImmediate finds it: a run of ones, rotated,
  // repeated in elements of 2..64 bits.
  Result := False;
  Bits := 0;
  var RegSize: Cardinal := 32;
  if Is64 then
    RegSize := 64;
  if (Value = 0) or (Value = not UInt64(0)) then
    Exit;
  if not Is64 and (((Value shr 32) <> 0) or (Value = $FFFFFFFF)) then
    Exit;
  var Size := RegSize;
  repeat
    Size := Size div 2;
    var M := (UInt64(1) shl Size) - 1;
    if (Value and M) <> ((Value shr Size) and M) then
    begin
      Size := Size * 2;
      Break;
    end;
  until Size <= 2;
  var Mask := not UInt64(0) shr (64 - Size);
  var V := Value and Mask;
  var Rot, Ones: Cardinal;
  if IsShiftedMask(V) then
  begin
    Rot := TrailingZeros(V);
    Ones := TrailingOnes(V shr Rot);
  end
  else
  begin
    V := V or not Mask;
    if not IsShiftedMask(not V) then
      Exit;
    var Lead := LeadingOnes(V);
    Rot := 64 - Lead;
    Ones := Lead + TrailingOnes(V) - (64 - Size);
  end;
  var Immr := (Size - Rot) and (Size - 1);
  var NImms := (not UInt64(Size - 1) shl 1) or (Ones - 1);
  var N := ((NImms shr 6) and 1) xor 1;
  Bits := (Cardinal(N) shl 22) or (Immr shl 16) or (Cardinal(NImms and $3F) shl 10);
  Result := True;
end;

constructor TJitAsmA64.Create(Size: NativeInt);
const
  Phys: array[TJitReg] of Byte = (19, 20, 21, 22, 23, 24, 0, 9, 10, 11, 12, 13, 14, 26);
begin
  for var R := Low(TJitReg) to High(TJitReg) do
    FPhys[R] := Phys[R];
  inherited Create(Size);
end;

procedure TJitAsmA64.I(V: Cardinal);
begin
  D(V);
end;

procedure TJitAsmA64.LoadImm(Is64: Boolean; Rd: Integer; Value: UInt64);
begin
  // MOVZ (MOVN when more of its 16-bit pieces are all ones than all zeros),
  // then MOVK for each other piece; 32 bits zero-extend. (Not LDR from a
  // pool after the code: those loads miss the data cache.)
  var Pieces := 2;
  if Is64 then
    Pieces := 4
  else
    Value := Value and $FFFFFFFF;
  var Zeros := 0;
  var Ones := 0;
  for var K := 0 to Pieces - 1 do
    case (Value shr (16 * K)) and $FFFF of
      0: Inc(Zeros);
      $FFFF: Inc(Ones);
    end;
  var Inverted := Ones > Zeros;
  var Needed := Pieces - Zeros;
  if Inverted then
    Needed := Pieces - Ones;
  var Sf := Cardinal(Ord(Is64)) shl 31;
  var Skip: Cardinal := 0;
  if Inverted then
    Skip := $FFFF;
  var First := True;
  for var K := 0 to Pieces - 1 do
  begin
    var C := Cardinal((Value shr (16 * K)) and $FFFF);
    if (C = Skip) and ((K > 0) or (Needed > 0)) then
      Continue;
    if not First then
      I(Sf or $72800000 or (Cardinal(K) shl 21) or (C shl 5) or Cardinal(Rd))                  // movk
    else if Inverted then
      I(Sf or $12800000 or (Cardinal(K) shl 21) or ((not C and $FFFF) shl 5) or Cardinal(Rd))  // movn
    else
      I(Sf or $52800000 or (Cardinal(K) shl 21) or (C shl 5) or Cardinal(Rd));                 // movz
    First := False;
  end;
end;

procedure TJitAsmA64.MovReg(Is64: Boolean; Rd, Rm: Integer);
begin
  // orr Rd, zr, Rm (32 bits zero-extend)
  I((Cardinal(Ord(Is64)) shl 31) or $2A0003E0 or (Cardinal(Rm) shl 16) or Cardinal(Rd));
end;

procedure TJitAsmA64.AddImm(Is64: Boolean; Rd, Rn: Integer; Value: Int64);
begin
  // Rd := Rn + Value: add or sub with a 12-bit constant (shifted by 12 or
  // not), else through x8.
  var Sf := Cardinal(Ord(Is64)) shl 31;
  var Op: Cardinal := $11000000;
  var V := Value;
  if V < 0 then
  begin
    Op := $51000000;
    V := -V;
  end;
  if V < 4096 then
    I(Sf or Op or (Cardinal(V) shl 10) or (Cardinal(Rn) shl 5) or Cardinal(Rd))
  else if ((V and $FFF) = 0) and (V < 4096 * 4096) then
    I(Sf or Op or (1 shl 22) or (Cardinal(V shr 12) shl 10) or (Cardinal(Rn) shl 5) or Cardinal(Rd))
  else
  begin
    LoadImm(Is64, aTmp, UInt64(Value));
    I(Sf or $0B000000 or (aTmp shl 16) or (Cardinal(Rn) shl 5) or Cardinal(Rd));                // add (register)
  end;
end;

function TJitAsmA64.Direct(var Base, Disp: Integer; Size: Integer): Boolean;
begin
  // Whether [Base + Disp] is one load or store: a scaled 12-bit offset (from
  // Self + 32 KB past 32 KB), an unscaled 9-bit one.
  if (Disp >= 0) and (Disp mod Size = 0) and (Disp div Size < 4096) then
    Exit(True);
  if (Base = FPhys[jrSelf]) and (Disp >= A64High) and ((Disp - A64High) mod Size = 0) and
    ((Disp - A64High) div Size < 4096) then
  begin
    Base := aHigh;
    Dec(Disp, A64High);
    Exit(True);
  end;
  if Base = FPhys[jrSelf] then
    for var K := 0 to FWins - 1 do
      if (Disp >= FWinBase[K]) and ((Disp - FWinBase[K]) mod Size = 0) and ((Disp - FWinBase[K]) div Size < 4096) then
      begin
        Base := A64WinReg[K];
        Dec(Disp, FWinBase[K]);
        Exit(True);
      end;
  Result := (Disp >= -256) and (Disp < 256);
end;

function TJitAsmA64.HasS4: Boolean;
begin
  Result := True;
end;

procedure TJitAsmA64.AddWindow(Disp: Integer);
begin
  // Self + Disp (rounded down to 4 KB) in the next window register, unless
  // a window reaches it already (8-byte fields: 32 KB from its base).
  if (Disp < 0) or (Disp >= 4096 * 4096) then
    Exit;
  if (Disp >= A64High) and (Disp - A64High < 32768) then
    Exit;
  for var K := 0 to FWins - 1 do
    if (Disp >= FWinBase[K]) and (Disp - FWinBase[K] < 32768) then
      Exit;
  if FWins < Length(FWinBase) then
  begin
    FWinBase[FWins] := Disp and not $FFF;
    Inc(FWins);
  end;
end;

procedure TJitAsmA64.LoadStore(Store: Boolean; Size, Rt, Base, Disp: Integer);
begin
  // ldrb/strb, ldr/str w or x at [Base + Disp]: one instruction where
  // Direct, else Disp in x16 as an index. Loads zero-extend.
  var SizeBits: Cardinal := 3;
  case Size of
    1: SizeBits := 0;
    4: SizeBits := 2;
  end;
  var B := Base;
  var Dsp := Disp;
  var One := Direct(B, Dsp, Size);
  var Common := (SizeBits shl 30) or (Cardinal(Ord(not Store)) shl 22) or (Cardinal(B) shl 5) or Cardinal(Rt);
  if One and (Dsp >= 0) and (Dsp mod Size = 0) and (Dsp div Size < 4096) then
    I(Common or $39000000 or (Cardinal(Dsp div Size) shl 10))
  else if One then
    I(Common or $38000000 or ((Cardinal(Dsp) and $1FF) shl 12))
  else
  begin
    LoadImm(True, aIP0, UInt64(Int64(Disp)));
    I(Common or $38206800 or (aIP0 shl 16));
  end;
end;

function TJitAsmA64.Fetch(W: TJitWidth; const Op: TJitOp; Scratch: Integer): Integer;
begin
  // The operand's value in a register: its own, or Scratch with a constant
  // (W bits), memory (W bits, zero-extended) or an address.
  Result := Scratch;
  case Op.Kind of
    okReg:
      Result := FPhys[Op.Reg];
    okImm:
      LoadImm(W = jw64, Scratch, UInt64(Op.Imm));
    okMem:
      LoadStore(False, A64Bytes[W], Scratch, FPhys[Op.Reg], Op.Disp);
    okAddr:
      AddImm(True, Scratch, FPhys[Op.Reg], Op.Disp);
  end;
end;

procedure TJitAsmA64.Move(W: TJitWidth; const Dst, Src: TJitOp);
begin
  if Dst.Kind = okReg then
  begin
    var R := FPhys[Dst.Reg];
    case Src.Kind of
      okReg:
        case W of
          jw8:
            I($53001C00 or (Cardinal(FPhys[Src.Reg]) shl 5) or Cardinal(R));                     // uxtb
          jw32:
            MovReg(False, R, FPhys[Src.Reg]);
          jw64:
            if R <> FPhys[Src.Reg] then
              MovReg(True, R, FPhys[Src.Reg]);
        end;
      okImm:
        // (As x64's: a constant for 8 or 32 bits fills 32.)
        LoadImm(W = jw64, R, UInt64(Src.Imm));
      okMem:
        LoadStore(False, A64Bytes[W], R, FPhys[Src.Reg], Src.Disp);
      okAddr:
        AddImm(True, R, FPhys[Src.Reg], Src.Disp);
    end;
  end
  else if (Dst.Kind = okMem) and (Src.Kind in [okReg, okImm]) then
  begin
    var S := aZR;
    if (Src.Kind = okReg) or (Src.Imm <> 0) then
      S := Fetch(W, Src, aIP1);
    LoadStore(True, A64Bytes[W], S, FPhys[Dst.Reg], Dst.Disp);
  end
  else
    raise EInvalidOpException.Create('JIT: no such move');
end;

procedure TJitAsmA64.AluReg(Op: TJitAlu; W: TJitWidth; Rd: Integer; const Src: TJitOp);
begin
  // Rd := Rd op Src, 64 bits or 32 (zero-extended).
  var Sf := Cardinal(Ord(W = jw64)) shl 31;
  if Src.Kind = okImm then
  begin
    if Op in [jaAdd, jaSub] then
    begin
      var V := Src.Imm;
      if Op = jaSub then
        V := -V;
      AddImm(W = jw64, Rd, Rd, V);
      Exit;
    end;
    var V := UInt64(Src.Imm);
    if W <> jw64 then
      V := V and $FFFFFFFF;
    var Bits: Cardinal;
    if A64LogicalImm(V, W = jw64, Bits) then
    begin
      I(Sf or A64AluImm[Op] or Bits or (Cardinal(Rd) shl 5) or Cardinal(Rd));
      Exit;
    end;
  end;
  var S := Fetch(W, Src, aTmp);
  I(Sf or A64AluReg[Op] or (Cardinal(S) shl 16) or (Cardinal(Rd) shl 5) or Cardinal(Rd));
end;

procedure TJitAsmA64.Alu(Op: TJitAlu; W: TJitWidth; const Dst, Src: TJitOp);
begin
  if (Dst.Kind = okReg) and (W <> jw8) and (Src.Kind <> okAddr) then
    AluReg(Op, W, FPhys[Dst.Reg], Src)
  else if (Dst.Kind = okMem) and (Src.Kind in [okReg, okImm]) then
  begin
    // In x17, then back (8 bits: the low byte of a 32-bit operation); the
    // address in x16 once where it takes more than the instruction.
    var Size := A64Bytes[W];
    var B: Integer := FPhys[Dst.Reg];
    var Dsp := Dst.Disp;
    var B1 := B;
    var D1 := Dsp;
    if not Direct(B1, D1, Size) then
    begin
      LoadImm(True, aIP0, UInt64(Int64(Dsp)));
      I($8B000000 or (aIP0 shl 16) or (Cardinal(B) shl 5) or aIP0);                              // add x16, B, x16
      B := aIP0;
      Dsp := 0;
    end;
    LoadStore(False, Size, aIP1, B, Dsp);
    AluReg(Op, W, aIP1, Src);
    LoadStore(True, Size, aIP1, B, Dsp);
  end
  else
    raise EInvalidOpException.Create('JIT: no such operation');
end;

procedure TJitAsmA64.Shift(Op: TJitShift; W: TJitWidth; Dst: TJitReg; Count: Integer);
begin
  // lsl, lsr #Count as ubfm, asr as sbfm (8 bits: as x64's, 32).
  var R := Cardinal(FPhys[Dst]);
  var C := Cardinal(Count);
  if W = jw64 then
    case Op of
      jsShl: I($D3400000 or (((64 - C) and 63) shl 16) or ((63 - C) shl 10) or (R shl 5) or R);
      jsShr: I($D3400000 or (C shl 16) or (63 shl 10) or (R shl 5) or R);
      jsSar: I($93400000 or (C shl 16) or (63 shl 10) or (R shl 5) or R);
    end
  else
    case Op of
      jsShl: I($53000000 or (((32 - C) and 31) shl 16) or ((31 - C) shl 10) or (R shl 5) or R);
      jsShr: I($53000000 or (C shl 16) or (31 shl 10) or (R shl 5) or R);
      jsSar: I($13000000 or (C shl 16) or (31 shl 10) or (R shl 5) or R);
    end;
end;

procedure TJitAsmA64.SignExtend(W: TJitWidth; Dst: TJitReg);
begin
  // sxtb, sxtw (sbfm Xd, Xn, #0, #7 or #31)
  var R := Cardinal(FPhys[Dst]);
  case W of
    jw8:
      I($93401C00 or (R shl 5) or R);
    jw32:
      I($93407C00 or (R shl 5) or R);
  end;
end;

procedure TJitAsmA64.EmitCompare(W: TJitWidth; const A, B: TJitOp);
begin
  if W = jw8 then
  begin
    // The bytes in the top of 32-bit registers (lsl #24): their signed and
    // unsigned order both hold.
    var RA := Fetch(jw8, A, aIP1);
    I($53000000 or (8 shl 16) or (7 shl 10) or (Cardinal(RA) shl 5) or aIP1);                   // lsl w17, wA, #24
    var RB := aTmp;
    if B.Kind = okImm then
    begin
      if Byte(B.Imm) = 0 then
        RB := aZR
      else
        LoadImm(False, aTmp, UInt64(Byte(B.Imm)) shl 24);
    end
    else
    begin
      var R := Fetch(jw8, B, aTmp);
      I($53000000 or (8 shl 16) or (7 shl 10) or (Cardinal(R) shl 5) or aTmp);                  // lsl w8, wB, #24
    end;
    I($6B000000 or (Cardinal(RB) shl 16) or (aIP1 shl 5) or aZR);                                // cmp w17, wB
    Exit;
  end;
  var Sf := Cardinal(Ord(W = jw64)) shl 31;
  var RA := Fetch(W, A, aIP1);
  if B.Kind = okImm then
  begin
    // (As x64's: 32 bits compare a 32-bit constant.)
    var V := B.Imm;
    if W = jw32 then
      V := Integer(V);
    if (V >= 0) and (V < 4096) then
      I(Sf or $71000000 or (Cardinal(V) shl 10) or (Cardinal(RA) shl 5) or aZR)                 // cmp
    else if (V < 0) and (V > -4096) then
      I(Sf or $31000000 or (Cardinal(-V) shl 10) or (Cardinal(RA) shl 5) or aZR)                // cmn
    else
    begin
      LoadImm(W = jw64, aTmp, UInt64(V));
      I(Sf or $6B000000 or (aTmp shl 16) or (Cardinal(RA) shl 5) or aZR);
    end;
  end
  else
  begin
    var RB := Fetch(W, B, aTmp);
    I(Sf or $6B000000 or (Cardinal(RB) shl 16) or (Cardinal(RA) shl 5) or aZR);
  end;
end;

procedure TJitAsmA64.EmitTest(W: TJitWidth; const A, B: TJitOp);
begin
  // tst: a bitmask constant where it is one (8 bits: of the low byte); 8
  // bits of two registers: and, then tst #$FF.
  var Sf := Cardinal(Ord(W = jw64)) shl 31;
  var RA := Fetch(W, A, aIP1);
  var Mask: UInt64 := 0;
  var HasMask := False;
  if B.Kind = okImm then
  begin
    HasMask := True;
    Mask := UInt64(B.Imm);
    if W = jw8 then
      Mask := Mask and $FF
    else if W = jw32 then
      Mask := Mask and $FFFFFFFF;
  end
  else if (W = jw8) and (B.Kind = okReg) and (FPhys[B.Reg] = RA) and (A.Kind = okReg) then
  begin
    HasMask := True;
    Mask := $FF;
  end;
  var Bits: Cardinal;
  if HasMask and A64LogicalImm(Mask, W = jw64, Bits) then
  begin
    I(Sf or $72000000 or Bits or (Cardinal(RA) shl 5) or aZR);
    Exit;
  end;
  var RB: Integer;
  if HasMask then
  begin
    RB := aTmp;
    LoadImm(W = jw64, aTmp, Mask);
  end
  else
    RB := Fetch(W, B, aTmp);
  if W = jw8 then
  begin
    I($0A000000 or (Cardinal(RB) shl 16) or (Cardinal(RA) shl 5) or aTmp);                       // and w8, wA, wB
    I($72001C00 or (aTmp shl 5) or aZR);                                                         // tst w8, #$FF
  end
  else
    I(Sf or $6A000000 or (Cardinal(RB) shl 16) or (Cardinal(RA) shl 5) or aZR);                 // tst
end;

function TJitAsmA64.EmitJumpIf(Cond: TJitCond): NativeInt;
begin
  // b.cond to a label: within the function (1 MB).
  Result := Offset;
  I($54000000 or A64Cond[Cond]);
end;

function TJitAsmA64.EmitJump: NativeInt;
begin
  Result := Offset;
  I($14000000);
end;

procedure TJitAsmA64.EmitJumpIfTo(Cond: TJitCond; Target: NativeInt);
begin
  // To code written before: b.cond within 1 MB, else b.<opposite> over a b
  // (128 MB: the buffer).
  var Delta := (Target - Offset) div 4;
  if (Delta >= -$40000) and (Delta < $40000) then
    I($54000000 or ((Cardinal(Delta) and $7FFFF) shl 5) or A64Cond[Cond])
  else
  begin
    I($54000000 or (2 shl 5) or (A64Cond[Cond] xor 1));
    PatchJump(EmitJump, Target);
  end;
end;

function A64Short(Ins: Cardinal): Boolean; inline;
begin
  // b.cond, cbz, cbnz: a 19-bit offset in bits 5..23.
  Result := ((Ins and $FF000010) = $54000000) or ((Ins and $7E000000) = $34000000);
end;

function TJitAsmA64.EmitTestJump(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp): NativeInt;
begin
  // A register tested against itself for none or some bits (32 or 64): cbz,
  // cbnz.
  if (Cond in [jcEq, jcNe]) and (W <> jw8) and (A.Kind = okReg) and (B.Kind = okReg) and (A.Reg = B.Reg) then
  begin
    Result := Offset;
    I((Cardinal(Ord(W = jw64)) shl 31) or $34000000 or (Cardinal(Ord(Cond = jcNe)) shl 24) or FPhys[A.Reg]);
    Exit;
  end;
  Result := inherited EmitTestJump(Cond, W, A, B);
end;

procedure TJitAsmA64.PatchJump(Field, Target: NativeInt);
begin
  var Ins := PCardinal(Base + Field)^;
  var Delta := (Target - Field) div 4;
  if A64Short(Ins) then
  begin
    if (Delta < -$40000) or (Delta >= $40000) then
      raise EInvalidOpException.Create('JIT: a branch out of reach');
    PCardinal(Base + Field)^ := (Ins and $FF00001F) or ((Cardinal(Delta) and $7FFFF) shl 5);
  end
  else
  begin
    if (Delta < -$2000000) or (Delta >= $2000000) then
      raise EInvalidOpException.Create('JIT: a jump out of reach');
    PCardinal(Base + Field)^ := $14000000 or (Cardinal(Delta) and $3FFFFFF);
  end;
end;

function TJitAsmA64.JumpTargetOf(Field: NativeInt): NativeInt;
begin
  var Ins := PCardinal(Base + Field)^;
  var Delta: NativeInt;
  if A64Short(Ins) then
  begin
    Delta := NativeInt((Ins shr 5) and $7FFFF);
    if Delta >= $40000 then
      Dec(Delta, $80000);
  end
  else
  begin
    Delta := NativeInt(Ins and $3FFFFFF);
    if Delta >= $2000000 then
      Dec(Delta, $4000000);
  end;
  Result := Field + Delta * 4;
end;

procedure TJitAsmA64.MoveArgs(const Args: array of TJitOp);
begin
  // The arguments into x0..x3: x0 last, since T0 is there (no role is in
  // x1..x3).
  if Length(Args) > 4 then
    raise EInvalidOpException.Create('JIT: too many arguments');
  for var N := 1 to Length(Args) do
  begin
    var K := N mod Length(Args);
    case Args[K].Kind of
      okReg:
        if FPhys[Args[K].Reg] <> K then
          MovReg(True, K, FPhys[Args[K].Reg]);
      okImm:
        LoadImm(True, K, UInt64(Args[K].Imm));
      okMem:
        LoadStore(False, 8, K, FPhys[Args[K].Reg], Args[K].Disp);
      okAddr:
        AddImm(True, K, FPhys[Args[K].Reg], Args[K].Disp);
    end;
  end;
end;

procedure TJitAsmA64.Call(Routine: Pointer; const Args: array of TJitOp);
begin
  MoveArgs(Args);
  var Delta := (NativeInt(Routine) - NativeInt(Here)) div 4;
  if ((NativeUInt(Routine) and 3) = 0) and (Delta >= -$2000000) and (Delta < $2000000) then
    I($94000000 or (Cardinal(Delta) and $3FFFFFF))                                               // bl
  else
  begin
    LoadImm(True, aIP0, UInt64(NativeUInt(Routine)));
    I($D63F0000 or (aIP0 shl 5));                                                               // blr x16
  end;
  if FPhys[jrT0] <> 0 then
    MovReg(True, FPhys[jrT0], 0);
end;

procedure TJitAsmA64.CallAt(const Routine: TJitOp; const Args: array of TJitOp);
begin
  if Routine.Kind <> okMem then
    raise EInvalidOpException.Create('JIT: no such call');
  MoveArgs(Args);
  LoadStore(False, 8, aIP0, FPhys[Routine.Reg], Routine.Disp);
  I($D63F0000 or (aIP0 shl 5));                                                                 // blr x16
  if FPhys[jrT0] <> 0 then
    MovReg(True, FPhys[jrT0], 0);
end;

procedure TJitAsmA64.JumpIndirect(const Target: TJitOp);
begin
  I($D61F0000 or (Cardinal(Fetch(jw64, Target, aIP0)) shl 5));                                  // br
end;

procedure TJitAsmA64.Enter;
begin
  I($A9BA7BFD);               // stp x29, x30, [sp, #-96]!
  I($910003FD);               // mov x29, sp
  I($A90153F3);               // stp x19, x20, [sp, #16]
  I($A9025BF5);               // stp x21, x22, [sp, #32]
  I($A90363F7);               // stp x23, x24, [sp, #48]
  I($A9046BF9);               // stp x25, x26, [sp, #64]
  I($A90573FB);               // stp x27, x28, [sp, #80]
  MovReg(True, FPhys[jrSelf], 0);
  MovReg(True, FPhys[jrCtx], 1);
  I($91402279);               // add x25, x19, #8, lsl #12
  for var K := 0 to FWins - 1 do
    // add xW, x19, #Base shr 12, lsl #12
    I($91400000 or (Cardinal(FWinBase[K] shr 12) shl 10) or (19 shl 5) or Cardinal(A64WinReg[K]));
end;

procedure TJitAsmA64.Leave(const Value: TJitOp);
begin
  if Value.Kind = okReg then
  begin
    if FPhys[Value.Reg] <> 0 then
      MovReg(True, 0, FPhys[Value.Reg]);
  end
  else
    Fetch(jw64, Value, 0);
  I($A94573FB);               // ldp x27, x28, [sp, #80]
  I($A9446BF9);               // ldp x25, x26, [sp, #64]
  I($A94363F7);               // ldp x23, x24, [sp, #48]
  I($A9425BF5);               // ldp x21, x22, [sp, #32]
  I($A94153F3);               // ldp x19, x20, [sp, #16]
  I($A8C67BFD);               // ldp x29, x30, [sp], #96
  I($D65F03C0);               // ret
end;

procedure TJitAsmA64.EnterJump;
begin
  Enter;
  MovReg(True, FPhys[jrT1], 3);
  I($D61F0000 or (2 shl 5));  // br x2
end;

{$IF JitSupported and Defined(MSWINDOWS)}

{ Win64 }

function RtlAddFunctionTable(FunctionTable: Pointer; EntryCount: DWORD; BaseAddress: UInt64): BOOL; stdcall;
  external kernel32;
function RtlDeleteFunctionTable(FunctionTable: Pointer): BOOL; stdcall; external kernel32;

type
  // The Win64 convention: arguments in RCX, RDX, R8, R9, the result in RAX;
  // RBX, RSI, RDI, R12..R15 kept by a callee (the fixed roles); 32 bytes of
  // shadow space above the return address, RSP 16-aligned at a call. Every
  // function has Enter's frame, so one unwind entry covers the buffer.
  TJitAsmWin64 = class(TJitAsmX64)
  private
    FTable: array[0..0] of record
      BeginAddress, EndAddress, UnwindData: Cardinal;
    end;
    FRegistered: Boolean;
  protected
    function Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte; override;
    procedure Release(Base: PByte); override;
    procedure FlushCode(P: PByte; Len: NativeInt); override;
  public
    constructor Create(Size: NativeInt);
    procedure Enter; override;
    procedure Leave(const Value: TJitOp); override;
  end;

const
  // UNWIND_INFO at the start of the buffer, for Enter: version 1, no flags,
  // 13-byte prologue, 7 codes (padded to 8), no frame register. Codes
  // (offset after the instruction, op | info shl 4), last first: sub rsp,40
  // (ALLOC_SMALL 4), push rdi, r14, r13, r12, rsi, rbx.
  UnwindInfo: array[0..19] of Byte = (
    $01, 13, 7, 0,
    13, $42,          // ALLOC_SMALL (40 - 8) / 8 = 4
    9, $70,           // PUSH_NONVOL RDI
    8, $E0,           // PUSH_NONVOL R14
    6, $D0,           // PUSH_NONVOL R13
    4, $C0,           // PUSH_NONVOL R12
    2, $60,           // PUSH_NONVOL RSI
    1, $30,           // PUSH_NONVOL RBX
    0, 0);
  Win64CodeStart = 64;

constructor TJitAsmWin64.Create(Size: NativeInt);
const
  Phys: array[TJitReg] of Byte = (rBX, rSI, rDI, r12, r13, r14, rAX, rCX, rDX, r8, r9, r10, r11, rAX);
begin
  for var R := Low(TJitReg) to High(TJitReg) do
    FPhys[R] := Phys[R];
  FArgs[0] := rCX;
  FArgs[1] := rDX;
  FArgs[2] := r8;
  FArgs[3] := r9;
  inherited Create(Size);
end;

function TJitAsmWin64.Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte;
begin
  // Read, write and execute: code is written while other code runs.
  Result := VirtualAlloc(nil, Size, MEM_COMMIT or MEM_RESERVE, PAGE_EXECUTE_READWRITE);
  if Result = nil then
    RaiseLastOSError;
  System.Move(UnwindInfo, Result^, SizeOf(UnwindInfo));
  FTable[0].BeginAddress := Win64CodeStart;
  FTable[0].EndAddress := Cardinal(Size);
  FTable[0].UnwindData := 0;
  FRegistered := RtlAddFunctionTable(@FTable, 1, UInt64(Result));
  CodeStart := Win64CodeStart;
end;

procedure TJitAsmWin64.Release(Base: PByte);
begin
  if FRegistered then
    RtlDeleteFunctionTable(@FTable);
  VirtualFree(Base, 0, MEM_RELEASE);
end;

procedure TJitAsmWin64.FlushCode(P: PByte; Len: NativeInt);
begin
  // (x64 keeps the instruction cache coherent; Windows asks for the call for
  // code written at run time.)
  FlushInstructionCache(GetCurrentProcess, P, Len);
end;

procedure TJitAsmWin64.Enter;
begin
  Emit([$53]);                // push rbx
  Emit([$56]);                // push rsi
  Emit([$41, $54]);           // push r12
  Emit([$41, $55]);           // push r13
  Emit([$41, $56]);           // push r14
  Emit([$57]);                // push rdi
  Emit([$48, $83, $EC, 40]);  // sub rsp, 40
  MoveX(jw64, X64Reg(FPhys[jrSelf]), X64Reg(FArgs[0]));
  MoveX(jw64, X64Reg(FPhys[jrCtx]), X64Reg(FArgs[1]));
end;

procedure TJitAsmWin64.Leave(const Value: TJitOp);
begin
  MoveX(jw64, X64Reg(rAX), X(Value));
  Emit([$48, $83, $C4, 40]);  // add rsp, 40
  Emit([$5F]);                // pop rdi
  Emit([$41, $5E]);           // pop r14
  Emit([$41, $5D]);           // pop r13
  Emit([$41, $5C]);           // pop r12
  Emit([$5E]);                // pop rsi
  Emit([$5B]);                // pop rbx
  Emit([$C3]);                // ret
end;

{$ENDIF}

{$IF JitSupported and Defined(LINUX)}

{ Linux x64 }

procedure __register_frame(Frame: Pointer); cdecl; external 'libgcc_s.so.1' name '__register_frame';
procedure __deregister_frame(Frame: Pointer); cdecl; external 'libgcc_s.so.1' name '__deregister_frame';

type
  // The System V convention: arguments in RDI, RSI, RDX, RCX, the result in
  // RAX; RBX, RBP, R12..R15 kept by a callee (the fixed roles; R12, which
  // would need a SIB byte as a base, for Extra), RSP 16-aligned at a call.
  // Every function has Enter's frame, so one DWARF frame description at the
  // start of the buffer (a CIE and an FDE, registered with libgcc's unwinder,
  // which the RTL raises exceptions through) covers it.
  TJitAsmSysV64 = class(TJitAsmX64)
  protected
    function Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte; override;
    procedure Release(Base: PByte); override;
    procedure FlushCode(P: PByte; Len: NativeInt); override;
  public
    constructor Create(Size: NativeInt);
    procedure Enter; override;
    procedure Leave(const Value: TJitOp); override;
  end;

const
  SysVCodeStart = 256;
  // The frame description (.eh_frame form) for Enter's frame, from the
  // buffer's first code on: a CIE (code alignment 1, data alignment -8,
  // return address register 16, FDE addresses absolute; at a function's
  // entry the CFA is RSP + 8, the return address at CFA - 8), an FDE for the
  // code (its start and length at offsets 32 and 40: CFA RSP + 64; RBX, RBP,
  // R12..R15 at CFA - 16 .. CFA - 56) and the terminator.
  SysVFrame: array[0..67] of Byte = (
    20, 0, 0, 0,  0, 0, 0, 0,  1, Ord('z'), Ord('R'), 0,  1, $78, 16, 1,  0,  $0C, 7, 8,  $90, 1,  0, 0,
    36, 0, 0, 0,  28, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  0,
    $0E, 64,  $83, 2,  $86, 3,  $8C, 4,  $8D, 5,  $8E, 6,  $8F, 7,  0,
    0, 0, 0, 0);

constructor TJitAsmSysV64.Create(Size: NativeInt);
const
  Phys: array[TJitReg] of Byte = (rBX, rBP, r13, r12, r14, r15, rAX, rCX, rDX, r8, r9, r10, r11, rAX);
begin
  for var R := Low(TJitReg) to High(TJitReg) do
    FPhys[R] := Phys[R];
  FArgs[0] := rDI;
  FArgs[1] := rSI;
  FArgs[2] := rDX;
  FArgs[3] := rCX;
  inherited Create(Size);
end;

function TJitAsmSysV64.Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte;
begin
  // Read, write and execute: blocks are compiled while others run.
  {$WARN SYMBOL_PLATFORM OFF}
  Result := mmap(nil, Size, PROT_READ or PROT_WRITE or PROT_EXEC, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  {$WARN SYMBOL_PLATFORM ON}
  if Result = MAP_FAILED then
    RaiseLastOSError;
  System.Move(SysVFrame, Result^, SizeOf(SysVFrame));
  PUInt64(Result + 32)^ := UInt64(Result + SysVCodeStart);
  PUInt64(Result + 40)^ := UInt64(Size - SysVCodeStart);
  __register_frame(Result);
  CodeStart := SysVCodeStart;
end;

procedure TJitAsmSysV64.Release(Base: PByte);
begin
  __deregister_frame(Base);
  munmap(Base, Size);
end;

procedure TJitAsmSysV64.FlushCode(P: PByte; Len: NativeInt);
begin
  // (x64 keeps the instruction cache coherent.)
end;

procedure TJitAsmSysV64.Enter;
begin
  Emit([$53]);                // push rbx
  Emit([$55]);                // push rbp
  Emit([$41, $54]);           // push r12
  Emit([$41, $55]);           // push r13
  Emit([$41, $56]);           // push r14
  Emit([$41, $57]);           // push r15
  Emit([$48, $83, $EC, 8]);   // sub rsp, 8
  MoveX(jw64, X64Reg(FPhys[jrSelf]), X64Reg(FArgs[0]));
  MoveX(jw64, X64Reg(FPhys[jrCtx]), X64Reg(FArgs[1]));
end;

procedure TJitAsmSysV64.Leave(const Value: TJitOp);
begin
  MoveX(jw64, X64Reg(rAX), X(Value));
  Emit([$48, $83, $C4, 8]);   // add rsp, 8
  Emit([$41, $5F]);           // pop r15
  Emit([$41, $5E]);           // pop r14
  Emit([$41, $5D]);           // pop r13
  Emit([$41, $5C]);           // pop r12
  Emit([$5D]);                // pop rbp
  Emit([$5B]);                // pop rbx
  Emit([$C3]);                // ret
end;

{$ENDIF}

{$IF JitSupported and Defined(ANDROID)}

{ Android ARM64 }

// The RTL's unwinder (LLVM libunwind, linked statically: __register_frame
// takes one FDE) and compiler-rt's __clear_cache (on every Android link).
procedure __register_frame(FDE: Pointer); cdecl; external 'libunwind.a' name '__register_frame';
procedure __deregister_frame(FDE: Pointer); cdecl; external 'libunwind.a' name '__deregister_frame';
procedure __clear_cache(Start, Stop: Pointer); cdecl; external 'libunwind.a' name '__clear_cache';

type
  // Memory from mmap, just above this library's code where it is free (most
  // code then calls its routines with BL); code written is made visible to
  // instruction fetch (__clear_cache); one DWARF frame description at the
  // start of the buffer (a CIE and an FDE) covers it, since every function
  // has Enter's frame.
  TJitAsmAndroid64 = class(TJitAsmA64)
  protected
    function Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte; override;
    procedure Release(Base: PByte); override;
    procedure FlushCode(P: PByte; Len: NativeInt); override;
  end;

const
  A64CodeStart = 256;
  A64FDE = 24;
  // The frame description (.eh_frame form) for Enter's frame: a CIE (code
  // alignment 1, data alignment -8, return address register x30, FDE
  // addresses absolute; the CFA is SP), an FDE for the code (its start and
  // length at offsets 32 and 40: CFA SP + 96; x29, x30, x19..x28 at
  // CFA - 96 .. CFA - 8) and the terminator.
  A64Frame: array[0..83] of Byte = (
    20, 0, 0, 0,  0, 0, 0, 0,  1, Ord('z'), Ord('R'), 0,  1, $78, 30, 1,  0,  $0C, 31, 0,  0, 0, 0, 0,
    52, 0, 0, 0,  28, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  0,
    $0E, 96,  $9D, 12,  $9E, 11,  $93, 10,  $94, 9,  $95, 8,  $96, 7,  $97, 6,  $98, 5,  $99, 4,  $9A, 3,
    $9B, 2,  $9C, 1,  0, 0, 0, 0, 0,
    0, 0, 0, 0);

function TJitAsmAndroid64.Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte;
begin
  // Read, write and execute: code is written while other code runs.
  var Near := Pointer((NativeUInt(@TJitAsmAndroid64.Allocate) + 32 shl 20) and not NativeUInt($1FFFFF));
  {$WARN SYMBOL_PLATFORM OFF}
  Result := mmap(Near, Size, PROT_READ or PROT_WRITE or PROT_EXEC, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  {$WARN SYMBOL_PLATFORM ON}
  if Result = MAP_FAILED then
    RaiseLastOSError;
  System.Move(A64Frame, Result^, SizeOf(A64Frame));
  PUInt64(Result + 32)^ := UInt64(Result + A64CodeStart);
  PUInt64(Result + 40)^ := UInt64(Size - A64CodeStart);
  __register_frame(Result + A64FDE);
  CodeStart := A64CodeStart;
end;

procedure TJitAsmAndroid64.Release(Base: PByte);
begin
  __deregister_frame(Base + A64FDE);
  munmap(Base, Size);
end;

procedure TJitAsmAndroid64.FlushCode(P: PByte; Len: NativeInt);
begin
  __clear_cache(P, P + Len);
end;

{$ENDIF}

{ The model }

type
  // An operand as the model keeps it (TJitOp's fields).
  TModelOperand = packed record
    Kind, Reg: Byte;
    Disp: Integer;
    Imm: Int64;
  end;

  // The operations (never $CC, Align's filler: the model skips those bytes).
  TModelCode = (mcMove = 1, mcAlu, mcShift, mcSignExtend, mcCompare, mcTest, mcJumpIf, mcJump, mcCall, mcCallAt,
    mcEnter, mcLeave, mcEnterJump, mcJumpIndirect);

  // One operation: its width, its TJitAlu, TJitShift or TJitCond (Sub), a
  // shift's count or a call's arguments (Count), a jump's target (Target,
  // the jump's field: ModelTarget bytes on), a call's routine.
  TModelOp = packed record
    Code, W, Sub, Count: Byte;
    Target: Integer;
    Routine: Pointer;
    A, B: TModelOperand;
    Args: array[0..3] of TModelOperand;
  end;

  PModelOp = ^TModelOp;

  // TJitAsm's operations kept and run in Pascal (Invoke). Each operation's
  // meaning is written here once: what every backend's instructions must do.
  // The forms some backend lacks raise as they are written (a constant
  // outside a 32-bit one, an 8-bit operation on a register, two memory
  // operands), so that code the model takes runs on every backend. After a
  // call the scratch registers but T0 hold garbage, and no flags are left
  // after a call, an operation or a shift (a jump on them raises).
  TJitAsmModel = class(TJitAsm)
  private
    FLastTest: Boolean;
    function Put(Code: TModelCode; W: TJitWidth): PModelOp;
  protected
    function Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte; override;
    procedure Release(Base: PByte); override;
    procedure FlushCode(P: PByte; Len: NativeInt); override;
    procedure EmitCompare(W: TJitWidth; const A, B: TJitOp); override;
    procedure EmitTest(W: TJitWidth; const A, B: TJitOp); override;
    function EmitJumpIf(Cond: TJitCond): NativeInt; override;
    function EmitJump: NativeInt; override;
    procedure PatchJump(Field, Target: NativeInt); override;
    function JumpTargetOf(Field: NativeInt): NativeInt; override;
    function HasS4: Boolean; override;
  public
    constructor Create(Size: NativeInt);
    procedure Move(W: TJitWidth; const Dst, Src: TJitOp); override;
    procedure Alu(Op: TJitAlu; W: TJitWidth; const Dst, Src: TJitOp); override;
    procedure Shift(Op: TJitShift; W: TJitWidth; Dst: TJitReg; Count: Integer); override;
    procedure SignExtend(W: TJitWidth; Dst: TJitReg); override;
    procedure Call(Routine: Pointer; const Args: array of TJitOp); override;
    procedure CallAt(const Routine: TJitOp; const Args: array of TJitOp); override;
    procedure Enter; override;
    procedure Leave(const Value: TJitOp); override;
    procedure EnterJump; override;
    procedure JumpIndirect(const Target: TJitOp); override;
    function Invoke(Code: Pointer; A0, A1, A2, A3: NativeUInt): NativeInt; override;
  end;

const
  ModelTarget = 4;
  // Room's estimates are for instructions; the model's operations are
  // larger.
  ModelRoomScale = 16;
  ModelPoison = UInt64($BAD0BAD0BAD0BAD0);

procedure ModelError(const What: string);
begin
  raise EInvalidOpException.Create('JIT: ' + What + ' (not on every backend)');
end;

function ModelOperand(const Op: TJitOp): TModelOperand;
begin
  Result.Kind := Ord(Op.Kind);
  Result.Reg := Ord(Op.Reg);
  Result.Disp := Op.Disp;
  Result.Imm := Op.Imm;
end;

function ConstantFits(Value: Int64; W: TJitWidth): Boolean;
begin
  // A constant every backend takes in memory or an operation: 8 bits any
  // (its low byte), 32 any 32-bit value, 64 a sign-extended 32-bit one.
  case W of
    jw8:
      Result := True;
    jw32:
      Result := (Value >= -Int64($80000000)) and (Value <= $FFFFFFFF);
  else
    Result := (Value >= -Int64($80000000)) and (Value <= $7FFFFFFF);
  end;
end;

constructor TJitAsmModel.Create(Size: NativeInt);
begin
  inherited Create(Size);
  FRoomScale := ModelRoomScale;
end;

function TJitAsmModel.Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte;
begin
  GetMem(Result, Size);
  CodeStart := 16;
end;

procedure TJitAsmModel.Release(Base: PByte);
begin
  FreeMem(Base);
end;

procedure TJitAsmModel.FlushCode(P: PByte; Len: NativeInt);
begin
end;

function TJitAsmModel.HasS4: Boolean;
begin
  Result := True;
end;

function TJitAsmModel.Put(Code: TModelCode; W: TJitWidth): PModelOp;
begin
  Need(SizeOf(TModelOp));
  Result := PModelOp(Here);
  FillChar(Result^, SizeOf(TModelOp), 0);
  Result.Code := Ord(Code);
  Result.W := Ord(W);
  Result.Target := -1;
  Inc(FUsed, SizeOf(TModelOp));
end;

procedure TJitAsmModel.Move(W: TJitWidth; const Dst, Src: TJitOp);
begin
  if Dst.Kind = okReg then
    // (Any source; a constant fills 32 bits for 8 and 32.)
  else if Dst.Kind = okMem then
  begin
    if not (Src.Kind in [okReg, okImm]) then
      ModelError('a move to memory from memory or an address');
    if (Src.Kind = okImm) and not ConstantFits(Src.Imm, W) then
      ModelError('a constant out of range');
  end
  else
    ModelError('a move to a constant or an address');
  var P := Put(mcMove, W);
  P.A := ModelOperand(Dst);
  P.B := ModelOperand(Src);
end;

procedure TJitAsmModel.Alu(Op: TJitAlu; W: TJitWidth; const Dst, Src: TJitOp);
begin
  if Dst.Kind = okReg then
  begin
    if W = jw8 then
      ModelError('an 8-bit operation on a register');
    if not (Src.Kind in [okReg, okImm, okMem]) then
      ModelError('an operation with an address');
  end
  else if Dst.Kind = okMem then
  begin
    if not (Src.Kind in [okReg, okImm]) then
      ModelError('an operation on memory with memory or an address');
  end
  else
    ModelError('an operation on a constant or an address');
  if (Src.Kind = okImm) and not ConstantFits(Src.Imm, W) then
    ModelError('a constant out of range');
  var P := Put(mcAlu, W);
  P.Sub := Ord(Op);
  P.A := ModelOperand(Dst);
  P.B := ModelOperand(Src);
end;

procedure TJitAsmModel.Shift(Op: TJitShift; W: TJitWidth; Dst: TJitReg; Count: Integer);
begin
  if (Count < 0) or ((W = jw64) and (Count > 63)) or ((W <> jw64) and (Count > 31)) then
    ModelError('a shift count out of range');
  var P := Put(mcShift, W);
  P.Sub := Ord(Op);
  P.Count := Count;
  P.A := ModelOperand(JReg(Dst));
end;

procedure TJitAsmModel.SignExtend(W: TJitWidth; Dst: TJitReg);
begin
  var P := Put(mcSignExtend, W);
  P.A := ModelOperand(JReg(Dst));
end;

procedure TJitAsmModel.EmitCompare(W: TJitWidth; const A, B: TJitOp);
begin
  if not (A.Kind in [okReg, okMem]) or not (B.Kind in [okReg, okImm, okMem]) or ((A.Kind = okMem) and (B.Kind = okMem)) then
    ModelError('no such comparison');
  if (B.Kind = okImm) and not ConstantFits(B.Imm, W) then
    ModelError('a constant out of range');
  var P := Put(mcCompare, W);
  P.A := ModelOperand(A);
  P.B := ModelOperand(B);
  FLastTest := False;
end;

procedure TJitAsmModel.EmitTest(W: TJitWidth; const A, B: TJitOp);
begin
  if not (A.Kind in [okReg, okMem]) or not (B.Kind in [okReg, okImm]) then
    ModelError('no such test');
  if (B.Kind = okImm) and not ConstantFits(B.Imm, W) then
    ModelError('a constant out of range');
  var P := Put(mcTest, W);
  P.A := ModelOperand(A);
  P.B := ModelOperand(B);
  FLastTest := True;
end;

function TJitAsmModel.EmitJumpIf(Cond: TJitCond): NativeInt;
begin
  if FLastTest and not (Cond in [jcEq, jcNe]) then
    ModelError('an order after a test');
  Result := Offset + ModelTarget;
  Put(mcJumpIf, jw64).Sub := Ord(Cond);
end;

function TJitAsmModel.EmitJump: NativeInt;
begin
  Result := Offset + ModelTarget;
  Put(mcJump, jw64);
end;

procedure TJitAsmModel.PatchJump(Field, Target: NativeInt);
begin
  PInteger(Base + Field)^ := Integer(Target);
end;

function TJitAsmModel.JumpTargetOf(Field: NativeInt): NativeInt;
begin
  Result := PInteger(Base + Field)^;
end;

procedure TJitAsmModel.Call(Routine: Pointer; const Args: array of TJitOp);
begin
  if Length(Args) > 4 then
    ModelError('more than four arguments');
  var P := Put(mcCall, jw64);
  P.Routine := Routine;
  P.Count := Length(Args);
  for var K := 0 to High(Args) do
    P.Args[K] := ModelOperand(Args[K]);
end;

procedure TJitAsmModel.CallAt(const Routine: TJitOp; const Args: array of TJitOp);
begin
  if Routine.Kind <> okMem then
    ModelError('a call through no memory');
  if Length(Args) > 4 then
    ModelError('more than four arguments');
  var P := Put(mcCallAt, jw64);
  P.A := ModelOperand(Routine);
  P.Count := Length(Args);
  for var K := 0 to High(Args) do
    P.Args[K] := ModelOperand(Args[K]);
end;

procedure TJitAsmModel.Enter;
begin
  Put(mcEnter, jw64);
end;

procedure TJitAsmModel.Leave(const Value: TJitOp);
begin
  Put(mcLeave, jw64).A := ModelOperand(Value);
end;

procedure TJitAsmModel.EnterJump;
begin
  Put(mcEnterJump, jw64);
end;

procedure TJitAsmModel.JumpIndirect(const Target: TJitOp);
begin
  if not (Target.Kind in [okReg, okMem]) then
    ModelError('no such indirect jump');
  Put(mcJumpIndirect, jw64).A := ModelOperand(Target);
end;

function TJitAsmModel.Invoke(Code: Pointer; A0, A1, A2, A3: NativeUInt): NativeInt;
type
  TFn0 = function: NativeUInt;
  TFn1 = function(A: NativeUInt): NativeUInt;
  TFn2 = function(A, B: NativeUInt): NativeUInt;
  TFn3 = function(A, B, C: NativeUInt): NativeUInt;
  TFn4 = function(A, B, C, D: NativeUInt): NativeUInt;
const
  Masks: array[TJitWidth] of UInt64 = ($FF, $FFFFFFFF, UInt64($FFFFFFFFFFFFFFFF));
var
  R: array[TJitReg] of UInt64;
  // The flags: none, of a comparison or of a test (FlagA the bits tested).
  FlagKind: Integer;
  FlagA, FlagB: UInt64;
  FlagW: TJitWidth;

  function Address(const O: TModelOperand): NativeUInt;
  begin
    Result := NativeUInt(R[TJitReg(O.Reg)] + UInt64(Int64(O.Disp)));
  end;

  function Load(A: NativeUInt; W: TJitWidth): UInt64;
  begin
    case W of
      jw8: Result := PByte(A)^;
      jw32: Result := PCardinal(A)^;
    else
      Result := PUInt64(A)^;
    end;
  end;

  procedure Store(A: NativeUInt; W: TJitWidth; V: UInt64);
  begin
    case W of
      jw8: PByte(A)^ := Byte(V);
      jw32: PCardinal(A)^ := Cardinal(V);
    else
      PUInt64(A)^ := V;
    end;
  end;

  function Value(const O: TModelOperand; W: TJitWidth): UInt64;
  begin
    // A source operand, W bits of it (registers whole: the callers mask).
    case TJitOpKind(O.Kind) of
      okReg: Result := R[TJitReg(O.Reg)];
      okImm: Result := UInt64(O.Imm);
      okMem: Result := Load(Address(O), W);
    else
      Result := Address(O);
    end;
  end;

  function Signed(V: UInt64; W: TJitWidth): Int64;
  begin
    case W of
      jw8: Result := ShortInt(Byte(V));
      jw32: Result := Integer(Cardinal(V));
    else
      Result := Int64(V);
    end;
  end;

  function ToOffset(A: UInt64): NativeInt;
  begin
    Result := NativeInt(A) - NativeInt(Base);
    if (Result < FCodeStart) or (Result >= FUsed) then
      raise EInvalidOpException.Create('JIT model: a jump out of the code');
  end;

begin
  for var X := Low(TJitReg) to High(TJitReg) do
    R[X] := ModelPoison;
  FlagKind := 0;
  FlagA := 0;
  FlagB := 0;
  FlagW := jw64;
  var PC := ToOffset(UInt64(NativeUInt(Code)));
  while True do
  begin
    if Base[PC] = $CC then
    begin
      Inc(PC);
      Continue;
    end;
    var P := PModelOp(Base + PC);
    var W := TJitWidth(P.W);
    var Next := PC + SizeOf(TModelOp);
    case TModelCode(P.Code) of
      mcMove:
        if TJitOpKind(P.A.Kind) = okReg then
        begin
          var V: UInt64;
          case TJitOpKind(P.B.Kind) of
            okReg: V := R[TJitReg(P.B.Reg)] and Masks[W];
            okImm:
              if W = jw64 then
                V := UInt64(P.B.Imm)
              else
                V := UInt64(P.B.Imm) and $FFFFFFFF;
            okMem: V := Load(Address(P.B), W);
          else
            V := Address(P.B);
          end;
          R[TJitReg(P.A.Reg)] := V;
        end
        else
          Store(Address(P.A), W, Value(P.B, W));
      mcAlu:
        begin
          var Dst := Value(P.A, W) and Masks[W];
          var Src := Value(P.B, W) and Masks[W];
          case TJitAlu(P.Sub) of
            jaAdd: Dst := Dst + Src;
            jaSub: Dst := Dst - Src;
            jaAnd: Dst := Dst and Src;
            jaOr: Dst := Dst or Src;
          else
            Dst := Dst xor Src;
          end;
          Dst := Dst and Masks[W];
          if TJitOpKind(P.A.Kind) = okReg then
            R[TJitReg(P.A.Reg)] := Dst
          else
            Store(Address(P.A), W, Dst);
          FlagKind := 0;
        end;
      mcShift:
        begin
          var X := TJitReg(P.A.Reg);
          var C := P.Count;
          if W = jw64 then
            case TJitShift(P.Sub) of
              jsShl: R[X] := R[X] shl C;
              jsShr: R[X] := R[X] shr C;
            else
              if Int64(R[X]) < 0 then
                R[X] := not ((not R[X]) shr C)
              else
                R[X] := R[X] shr C;
            end
          else
          begin
            var V := Cardinal(R[X]);
            case TJitShift(P.Sub) of
              jsShl: V := V shl C;
              jsShr: V := V shr C;
            else
              if Integer(V) < 0 then
                V := not ((not V) shr C)
              else
                V := V shr C;
            end;
            R[X] := V;
          end;
          FlagKind := 0;
        end;
      mcSignExtend:
        begin
          var X := TJitReg(P.A.Reg);
          R[X] := UInt64(Signed(R[X], W));
        end;
      mcCompare:
        begin
          FlagA := Value(P.A, W) and Masks[W];
          FlagB := Value(P.B, W) and Masks[W];
          FlagW := W;
          FlagKind := 1;
        end;
      mcTest:
        begin
          FlagA := Value(P.A, W) and Value(P.B, W) and Masks[W];
          FlagKind := 2;
        end;
      mcJumpIf:
        begin
          if FlagKind = 0 then
            raise EInvalidOpException.Create('JIT model: a jump on flags an operation or a call changed');
          var Taken: Boolean;
          if FlagKind = 2 then
            Taken := (FlagA = 0) = (TJitCond(P.Sub) = jcEq)
          else
          begin
            var SA := Signed(FlagA, FlagW);
            var SB := Signed(FlagB, FlagW);
            case TJitCond(P.Sub) of
              jcEq: Taken := FlagA = FlagB;
              jcNe: Taken := FlagA <> FlagB;
              jcLt: Taken := SA < SB;
              jcLe: Taken := SA <= SB;
              jcGt: Taken := SA > SB;
              jcGe: Taken := SA >= SB;
              jcBelow: Taken := FlagA < FlagB;
              jcBelowEq: Taken := FlagA <= FlagB;
              jcAbove: Taken := FlagA > FlagB;
            else
              Taken := FlagA >= FlagB;
            end;
          end;
          if Taken then
            Next := P.Target;
        end;
      mcJump:
        Next := P.Target;
      mcCall, mcCallAt:
        begin
          var Routine: Pointer;
          if TModelCode(P.Code) = mcCall then
            Routine := P.Routine
          else
            Routine := Pointer(NativeUInt(Value(P.A, jw64)));
          var Args: array[0..3] of NativeUInt;
          for var K := 0 to P.Count - 1 do
            Args[K] := NativeUInt(Value(P.Args[K], jw64));
          var Res: NativeUInt;
          case P.Count of
            0: Res := TFn0(Routine)();
            1: Res := TFn1(Routine)(Args[0]);
            2: Res := TFn2(Routine)(Args[0], Args[1]);
            3: Res := TFn3(Routine)(Args[0], Args[1], Args[2]);
          else
            Res := TFn4(Routine)(Args[0], Args[1], Args[2], Args[3]);
          end;
          for var X := jrT1 to jrT6 do
            R[X] := ModelPoison;
          R[jrT0] := Res;
          FlagKind := 0;
        end;
      mcEnter, mcEnterJump:
        begin
          R[jrSelf] := A0;
          R[jrCtx] := A1;
          if TModelCode(P.Code) = mcEnterJump then
          begin
            R[jrT1] := A3;
            Next := ToOffset(A2);
          end;
        end;
      mcLeave:
        Exit(NativeInt(Value(P.A, jw64)));
      mcJumpIndirect:
        Next := ToOffset(Value(P.A, jw64));
    else
      raise EInvalidOpException.Create('JIT model: no operation here');
    end;
    PC := Next;
  end;
end;

function CreateJitModel(Size: NativeInt): TJitAsm;
begin
  Result := TJitAsmModel.Create(Size);
end;

function CreateJitAsm(Size: NativeInt): TJitAsm;
begin
  {$IF JitSupported}
  try
    {$IF Defined(MSWINDOWS)}
    Result := TJitAsmWin64.Create(Size);
    {$ELSEIF Defined(ANDROID)}
    Result := TJitAsmAndroid64.Create(Size);
    {$ELSE}
    Result := TJitAsmSysV64.Create(Size);
    {$ENDIF}
  except
    // No executable memory here (a system that forbids it): the blocks run
    // interpreted.
    on EOSError do
      Result := nil;
  end;
  {$ELSE}
  Result := nil;
  {$ENDIF}
end;

end.
