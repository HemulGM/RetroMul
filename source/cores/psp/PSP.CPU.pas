unit PSP.CPU;

{$Q-}{$R-}{$POINTERMATH ON}

interface

uses
  System.SysUtils, PSP.Memory, PSP.VFPU;

type
  EPSPInstruction = class(Exception);

  TPSPCPUContext = record
    R: array[0..31] of Cardinal;
    FPR: array[0..31] of Cardinal;
    FCR31: Cardinal;
    VFPU: TPSPVFPU;
    PC, NextPC, Hi, Lo: Cardinal;
    PendingDelay, InDelay: Boolean;
  end;

  TPSPCPU = class;

  TPSPSyscall = procedure(CPU: TPSPCPU; Code: Cardinal) of object;

  // Allegrex scalar interpreter. No R3000 load delay; branches have one slot.
  // Unsupported coprocessors/instructions stop with PC/opcode diagnostics.
  TPSPCPU = class
  private
    FMemory: TPSPMemory;
    FR: array[0..31] of Cardinal;
    FFPR: array[0..31] of Cardinal;
    FFCR31: Cardinal;
    FVFPU: TPSPVFPU;
    FPC, FNextPC, FCurrentPC, FHi, FLo: Cardinal;
    FInDelay, FPendingDelay, FYielded, FHalted: Boolean;
    FInstructions: UInt64;
    FInterruptEnabled: Boolean;
    FOnSyscall: TPSPSyscall;
    FLinked: Boolean;
    FLinkedAddress: Cardinal;
    FLinkedGeneration: UInt64;
    procedure SetRegister(Index: Integer; Value: Cardinal); inline;
    function GetRegister(Index: Integer): Cardinal; inline;
    procedure Branch(Taken: Boolean; Target: Cardinal; Likely: Boolean = False); inline;
    procedure Unsupported(Op: Cardinal);
    procedure Special(Op: Cardinal);
    procedure Special3(Op: Cardinal);
    procedure Cop1(Op: Cardinal);
    procedure Execute(Op: Cardinal);
    function Address(Op: Cardinal): Cardinal; inline;
    procedure CheckAlignment(Value, Mask: Cardinal); inline;
  public
    constructor Create(Memory: TPSPMemory);
    procedure Reset(Entry, Stack, GP: Cardinal);
    procedure Step; inline;
    procedure Run(Budget: Cardinal);
    procedure Yield;
    procedure Halt;
    procedure SetFloatResult(Value: Single);
    procedure SetPC(Value: Cardinal);
    function SaveContext: TPSPCPUContext;
    procedure LoadContext(const Context: TPSPCPUContext);
    property Registers[Index: Integer]: Cardinal read GetRegister write SetRegister;
    property PC: Cardinal read FPC;
    property CurrentPC: Cardinal read FCurrentPC;
    property Hi: Cardinal read FHi;
    property Lo: Cardinal read FLo;
    property Instructions: UInt64 read FInstructions;
    property Halted: Boolean read FHalted;
    property OnSyscall: TPSPSyscall read FOnSyscall write FOnSyscall;
    property InterruptEnabled: Boolean read FInterruptEnabled write FInterruptEnabled;
  end;

implementation

uses
  N64.SoftFloat{$IFDEF PSP_PROFILE}, PSP.Profile{$ENDIF};

// Wrap only guest arithmetic, independently of host compiler check settings.
{$IFOPT Q+}{$DEFINE PSP_RESTORE_Q}{$ENDIF}
{$IFOPT R+}{$DEFINE PSP_RESTORE_R}{$ENDIF}
{$Q-}{$R-}
function Add32(A, B: Cardinal): Cardinal; inline;
begin
  Result := A + B;
end;

function Sub32(A, B: Cardinal): Cardinal; inline;
begin
  Result := A - B;
end;

function Signed16(Value: Cardinal): Cardinal; inline;
begin
  Result := Cardinal(Integer(SmallInt(Value and $FFFF)));
end;

function ASR32(Value: Cardinal; Shift: Integer): Cardinal; inline;
begin
  Shift := Shift and 31;
  Result := Value shr Shift;
  if (Shift <> 0) and (Value and $80000000 <> 0) then
    Result := Result or ($FFFFFFFF shl (32 - Shift));
end;

function ROR32(Value: Cardinal; Shift: Integer): Cardinal; inline;
begin
  Shift := Shift and 31;
  if Shift = 0 then
    Exit(Value);
  Result := (Value shr Shift) or (Value shl (32 - Shift));
end;
{$IFDEF PSP_RESTORE_Q}{$Q+}{$ENDIF}
{$IFDEF PSP_RESTORE_R}{$R+}{$ENDIF}

constructor TPSPCPU.Create(Memory: TPSPMemory);
begin
  inherited Create;
  if Memory = nil then
    raise EArgumentNilException.Create('Memory');
  FMemory := Memory;
end;

procedure TPSPCPU.Reset(Entry, Stack, GP: Cardinal);
begin
  FillChar(FR, SizeOf(FR), 0);
  FillChar(FFPR, SizeOf(FFPR), 0);
  FFCR31 := $0E00;
  FVFPU.Reset;
  FInterruptEnabled := True;
  FLinked := False;
  FHi := 0;
  FLo := 0;
  FInstructions := 0;
  FHalted := False;
  FYielded := False;
  FR[29] := Stack;
  FR[28] := GP;
  SetPC(Entry);
end;

procedure TPSPCPU.SetFloatResult(Value: Single);
begin
  Move(Value, FFPR[0], 4);
end;

procedure TPSPCPU.SetPC(Value: Cardinal);
begin
  CheckAlignment(Value, 3);
  FPC := Value;
  FNextPC := Add32(Value, 4);
  FPendingDelay := False;
  FInDelay := False;
end;

function TPSPCPU.GetRegister(Index: Integer): Cardinal;
begin
  if (Index < 0) or (Index > 31) then
    raise EArgumentOutOfRangeException.Create('Register');
  Result := FR[Index];
end;

procedure TPSPCPU.SetRegister(Index: Integer; Value: Cardinal);
begin
  if (Index < 0) or (Index > 31) then
    raise EArgumentOutOfRangeException.Create('Register');
  if Index <> 0 then
    FR[Index] := Value;
end;

procedure TPSPCPU.CheckAlignment(Value, Mask: Cardinal);
begin
  if Value and Mask <> 0 then
    raise EPSPInstruction.CreateFmt('PSP: unaligned access %.8x at PC %.8x', [Value, FCurrentPC]);
end;

procedure TPSPCPU.Unsupported(Op: Cardinal);
begin
  raise EPSPInstruction.CreateFmt('PSP: unsupported Allegrex opcode %.8x at PC %.8x', [Op, FCurrentPC]);
end;

procedure TPSPCPU.Branch(Taken: Boolean; Target: Cardinal; Likely: Boolean);
begin
  if FInDelay then
    raise EPSPInstruction.CreateFmt('PSP: branch in delay slot at %.8x is not implemented', [FCurrentPC]);
  if Taken then
  begin
    FNextPC := Target;
    FPendingDelay := True;
  end
  else if Likely then
  begin
    FPC := FNextPC;
    FNextPC := Add32(FNextPC, 4);
  end
  else
    FPendingDelay := True;
end;

procedure TPSPCPU.Special(Op: Cardinal);
var
  Product: Int64;
  UProduct: UInt64;
begin
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31);
  var Shift := Integer((Op shr 6) and 31);
  var A := FR[S];
  var B := FR[T];
  case Op and 63 of
    0:
      SetRegister(D, B shl Shift);
    2:
      if S = 1 then
        SetRegister(D, ROR32(B, Shift))
      else if S = 0 then
        SetRegister(D, B shr Shift)
      else
        Unsupported(Op);
    3:
      SetRegister(D, ASR32(B, Shift));
    4:
      SetRegister(D, B shl (A and 31));
    6:
      if Shift = 1 then
        SetRegister(D, ROR32(B, A and 31))
      else if Shift = 0 then
        SetRegister(D, B shr (A and 31))
      else
        Unsupported(Op);
    7:
      SetRegister(D, ASR32(B, A and 31));
    8:
      Branch(True, A);
    9:
      begin
        SetRegister(D, Add32(FCurrentPC, 8));
        Branch(True, A);
      end;
    10:
      if B = 0 then
        SetRegister(D, A);
    11:
      if B <> 0 then
        SetRegister(D, A);
    12:
      if Assigned(FOnSyscall) then
        FOnSyscall(Self, (Op shr 6) and $FFFFF)
      else
        raise EPSPInstruction.CreateFmt('PSP: syscall without HLE at %.8x', [FCurrentPC]);
    13:
      raise EPSPInstruction.CreateFmt('PSP: guest BREAK at %.8x', [FCurrentPC]);
    15:
      ; // SYNC: bus stores complete synchronously.
      16:
      SetRegister(D, FHi);
    17:
      FHi := A;
    18:
      SetRegister(D, FLo);
    19:
      FLo := A;
    22, 23:
      begin
        var Value := A;
        if Op and 63 = 23 then
          Value := not Value;
        var Count := 0;
        while (Count < 32) and (Value and $80000000 = 0) do
        begin
          Inc(Count);
          Value := Value shl 1;
        end;
        SetRegister(D, Count);
      end;
    24:
      begin
        Product := Int64(Integer(A)) * Integer(B);
        FLo := Cardinal(UInt64(Product) and $FFFFFFFF);
        FHi := Cardinal(UInt64(Product) shr 32);
      end;
    25:
      begin
        UProduct := UInt64(A) * B;
        FLo := Cardinal(UProduct and $FFFFFFFF);
        FHi := Cardinal(UProduct shr 32);
      end;
    26:
      if B = 0 then
      begin
        FHi := A;
        if Integer(A) < 0 then
          FLo := 1
        else
          FLo := $FFFFFFFF;
      end
      else if (A = $80000000) and (B = $FFFFFFFF) then
      begin
        FLo := $80000000;
        FHi := 0;
      end
      else
      begin
        FLo := Cardinal(Integer(A) div Integer(B));
        FHi := Cardinal(Integer(A) mod Integer(B));
      end;
    27:
      begin
        FHi := A;
        FLo := $FFFFFFFF;
        if B <> 0 then
        begin
          FLo := A div B;
          FHi := A mod B;
        end;
      end;
    28, 29, 46, 47:
      begin
        var Accumulator := (UInt64(FHi) shl 32) or FLo;
        if Op and 1 = 0 then
          UProduct := UInt64(Int64(Integer(A)) * Integer(B))
        else
          UProduct := UInt64(A) * B;
        {$Q-}
        if Op and 63 < 32 then
          Accumulator := Accumulator + UProduct
        else
          Accumulator := Accumulator - UProduct;
        {$IFDEF PSP_RESTORE_Q}{$Q+}{$ENDIF}
        FHi := Cardinal(Accumulator shr 32);
        FLo := Cardinal(Accumulator and $FFFFFFFF);
      end;
    32, 33:
      SetRegister(D, Add32(A, B));
    34, 35:
      SetRegister(D, Sub32(A, B));
    36:
      SetRegister(D, A and B);
    37:
      SetRegister(D, A or B);
    38:
      SetRegister(D, A xor B);
    39:
      SetRegister(D, not (A or B));
    42:
      SetRegister(D, Ord(Integer(A) < Integer(B)));
    43:
      SetRegister(D, Ord(A < B));
    44:
      if Integer(A) > Integer(B) then
        SetRegister(D, A)
      else
        SetRegister(D, B);
    45:
      if Integer(A) < Integer(B) then
        SetRegister(D, A)
      else
        SetRegister(D, B);
  else
    Unsupported(Op);
  end;
end;

procedure TPSPCPU.Special3(Op: Cardinal);
begin
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31);
  var Shift := Integer((Op shr 6) and 31);
  case Op and 63 of
    0:
      begin
        if Shift + D + 1 > 32 then
          Unsupported(Op);
        var Mask := $FFFFFFFF shr (31 - D);
        SetRegister(T, (FR[S] shr Shift) and Mask);
      end;
    4:
      begin
        if D < Shift then
          Unsupported(Op);
        var Mask := ($FFFFFFFF shr (31 - (D - Shift))) shl Shift;
        SetRegister(T, (FR[T] and not Mask) or ((FR[S] shl Shift) and Mask));
      end;
    24:
      ; // Allegrex SPECIAL3 nop encoding.
      32:
      case Shift of
        2:
          SetRegister(D, ((FR[T] and $00FF00FF) shl 8) or ((FR[T] and $FF00FF00) shr 8));
        3:
          SetRegister(D, (FR[T] shl 24) or ((FR[T] and $FF00) shl 8) or
            ((FR[T] shr 8) and $FF00) or (FR[T] shr 24));
        16:
          SetRegister(D, Cardinal(Integer(ShortInt(FR[T] and $FF))));
        20:
          begin
            var V := FR[T];
            var Reversed: Cardinal := 0;
            for var I := 0 to 31 do
            begin
              Reversed := (Reversed shl 1) or (V and 1);
              V := V shr 1;
            end;
            SetRegister(D, Reversed);
          end;
        24:
          SetRegister(D, Signed16(FR[T]));
      else
        Unsupported(Op);
      end;
  else
    Unsupported(Op);
  end;
end;

function TPSPCPU.Address(Op: Cardinal): Cardinal;
begin
  Result := Add32(FR[(Op shr 21) and 31], Signed16(Op));
end;

procedure TPSPCPU.Cop1(Op: Cardinal);
begin
  var Fmt := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  case Fmt of
    0:
      SetRegister(T, FFPR[S]);
    2:
      case S of
        0:
          SetRegister(T, $3351);
        31:
          SetRegister(T, FFCR31);
      else
        SetRegister(T, 0);
      end;
    4:
      FFPR[S] := FR[T];
    6:
      if S = 31 then
        FFCR31 := FR[T] and $0181FFFF;
    8:
      begin
        if T > 3 then
          Unsupported(Op);
        var Condition := FFCR31 and $800000 <> 0;
        Branch(Condition = (T and 1 <> 0), Add32(Add32(FCurrentPC, 4), Signed16(Op) shl 2), T and 2 <> 0);
      end;
    16, 20:
      begin
        var FunctionCode := Op and 63;
        var A := FFPR[S];
        var B := FFPR[T];
        var Rounding := Integer(FFCR31 and 3);
        if Fmt = 20 then
        begin
          if FunctionCode <> 32 then
            Unsupported(Op);
          var Converted: TSoftFloatResult;
          if not SFHostReady or not SFQuickConvert(A, 20, 16, Rounding, Converted) then
            Converted := SFConvert(A, 20, 16, Rounding);
          FFPR[D] := Cardinal(Converted.Bits);
          Exit;
        end;
        if FunctionCode >= 48 then
        begin
          var Unordered, Equal, Less: Boolean;
          SFCompare(A, B, 16, Unordered, Equal, Less);
          var Condition := ((FunctionCode and 1 <> 0) and Unordered) or
            ((FunctionCode and 2 <> 0) and Equal) or ((FunctionCode and 4 <> 0) and Less);
          FFCR31 := (FFCR31 and not Cardinal($800000)) or (Cardinal(Ord(Condition)) shl 23);
        end
        else
          case FunctionCode of
            0..4:
              begin
                var Value: TSoftFloatResult;
                if (Rounding <> 0) or not SFHostReady or not SFQuick(A, B, 16, FunctionCode, Value) then
                  Value := SFCalculate(A, B, 16, FunctionCode, Rounding);
                FFPR[D] := Cardinal(Value.Bits);
                if SFIsNaN(Value.Bits, 16) then
                  FFPR[D] := $7FC00000;
                FFCR31 := (FFCR31 and not Cardinal($1F000)) or (Value.Events shl 12) or (Value.Events shl 2);
                if (FFCR31 and $1000000 <> 0) and SFIsSubnormal(FFPR[D], 16) then
                  FFPR[D] := FFPR[D] and $80000000;
              end;
            5:
              FFPR[D] := A and $7FFFFFFF;
            6:
              FFPR[D] := A;
            7:
              FFPR[D] := A xor $80000000;
            12..15, 36:
              begin
                if FunctionCode <> 36 then
                  Rounding := FunctionCode - 12;
                if (FFCR31 and $1000000 <> 0) and SFIsSubnormal(A, 16) then
                  A := A and $80000000;
                var Value: TSoftFloatResult;
                if not SFHostReady or not SFQuickConvert(A, 16, 20, Rounding, Value) then
                  Value := SFConvert(A, 16, 20, Rounding);
                FFPR[D] := Cardinal(Value.Bits);
              // Allegrex saturates integer conversion, unlike R4300's indefinite result.
                if Value.Events and sfInvalid <> 0 then
                  if SFIsNaN(A, 16) or (A and $80000000 = 0) then
                    FFPR[D] := $7FFFFFFF
                  else
                    FFPR[D] := $80000000;
              end;
          else
            Unsupported(Op);
          end;
      end;
  else
    Unsupported(Op);
  end;
end;

procedure TPSPCPU.Execute(Op: Cardinal);
begin
  {$IFDEF PSP_PROFILE}
  if PSPProfileCollecting then
  begin
    Inc(PSPProfileOpcode[Op shr 26]);
    if Op shr 26 = 17 then
      Inc(PSPProfileCOP1[Op and 63]);
  end;
  {$ENDIF}
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  var A := FR[S];
  var B := FR[T];
  var Imm := Op and $FFFF;
  var Target := Add32(Add32(FCurrentPC, 4), Signed16(Op) shl 2);
  case Op shr 26 of
    0:
      Special(Op);
    1:
      begin
        if not (T in [0, 1, 2, 3, 16, 17, 18, 19]) then
          Unsupported(Op);
        var Taken := Integer(A) < 0;
        if T and 1 <> 0 then
          Taken := not Taken;
        if T and 16 <> 0 then
          SetRegister(31, Add32(FCurrentPC, 8));
        Branch(Taken, Target, T and 2 <> 0);
      end;
    2, 3:
      begin
        if Op shr 26 = 3 then
          SetRegister(31, Add32(FCurrentPC, 8));
        Branch(True, (Add32(FCurrentPC, 4) and $F0000000) or ((Op and $03FFFFFF) shl 2));
      end;
    4, 20:
      Branch(A = B, Target, Op shr 26 = 20);
    5, 21:
      Branch(A <> B, Target, Op shr 26 = 21);
    6, 22:
      Branch(Integer(A) <= 0, Target, Op shr 26 = 22);
    7, 23:
      Branch(Integer(A) > 0, Target, Op shr 26 = 23);
    8, 9:
      SetRegister(T, Add32(A, Signed16(Op)));
    10:
      SetRegister(T, Ord(Integer(A) < Integer(Signed16(Op))));
    11:
      SetRegister(T, Ord(A < Signed16(Op)));
    12:
      SetRegister(T, A and Imm);
    13:
      SetRegister(T, A or Imm);
    14:
      SetRegister(T, A xor Imm);
    15:
      SetRegister(T, Imm shl 16);
    17:
      Cop1(Op);
    18:
      case (Op shr 21) and 31 of
        3:
          begin
            var Index := Op and $FF;
            if Index < 128 then
              SetRegister(T, FVFPU.Registers[Index])
            else if Index < 144 then
              SetRegister(T, FVFPU.Control[Index - 128]);
          end;
        7:
          begin
            var Index := Op and $FF;
            if Index < 128 then
              FVFPU.Registers[Index] := B
            else if Index < 144 then
              FVFPU.Control[Index - 128] := B;
          end;
        8:
          begin
            var Condition := (FVFPU.Control[3] shr ((Op shr 18) and 7)) and 1 <> 0;
            Branch(Condition = (T and 1 <> 0), Target, T and 2 <> 0);
          end;
      else
        Unsupported(Op);
      end;
    28:
      case Op and 63 of
        36:
          SetRegister(T, Ord(FInterruptEnabled));
        38:
          FInterruptEnabled := B and 1 <> 0;
      else
        Unsupported(Op);
      end;
    31:
      Special3(Op);
    32:
      SetRegister(T, Cardinal(Integer(ShortInt(FMemory.Read8(Address(Op))))));
    33:
      begin
        var P := Address(Op);
        CheckAlignment(P, 1);
        SetRegister(T, Cardinal(Integer(SmallInt(FMemory.Read16(P)))));
      end;
    34:
      begin
        var P := Address(Op);
        var N := Integer(P and 3);
        var V := FMemory.Read32(P and $FFFFFFFC);
        var Mask := $00FFFFFF shr (N * 8);
        SetRegister(T, (B and Mask) or (V shl ((3 - N) * 8)));
      end;
    35:
      begin
        var P := Address(Op);
        CheckAlignment(P, 3);
        SetRegister(T, FMemory.Read32(P));
      end;
    36:
      SetRegister(T, FMemory.Read8(Address(Op)));
    37:
      begin
        var P := Address(Op);
        CheckAlignment(P, 1);
        SetRegister(T, FMemory.Read16(P));
      end;
    38:
      begin
        var P := Address(Op);
        var N := Integer(P and 3);
        var Mask: Cardinal := 0;
        if N <> 0 then
          Mask := $FFFFFFFF shl ((4 - N) * 8);
        SetRegister(T, (B and Mask) or (FMemory.Read32(P and $FFFFFFFC) shr (N * 8)));
      end;
    40:
      FMemory.Write8(Address(Op), Byte(B and $FF));
    41:
      begin
        var P := Address(Op);
        CheckAlignment(P, 1);
        FMemory.Write16(P, Word(B and $FFFF));
      end;
    42:
      begin
        var P := Address(Op);
        var N := Integer(P and 3);
        for var I := 0 to N do
          FMemory.Write8((P and $FFFFFFFC) + Cardinal(I), Byte((B shr ((3 - N + I) * 8)) and $FF));
      end;
    43:
      begin
        var P := Address(Op);
        CheckAlignment(P, 3);
        FMemory.Write32(P, B);
      end;
    46:
      begin
        var P := Address(Op);
        var N := Integer(P and 3);
        for var I := N to 3 do
          FMemory.Write8((P and $FFFFFFFC) + Cardinal(I), Byte((B shr ((I - N) * 8)) and $FF));
      end;
    47:
      ; // CACHE: no instruction/data cache is modelled yet.
      48:
      begin
        var P := Address(Op);
        CheckAlignment(P, 3);
        SetRegister(T, FMemory.Read32(P));
        FLinkedAddress := P and $3FFFFFFF;
        FLinkedGeneration := FMemory.WriteGeneration;
        FLinked := True;
      end;
    56:
      begin
        var P := Address(Op);
        CheckAlignment(P, 3);
        var Success := FLinked and (FLinkedAddress = P and $3FFFFFFF) and (FLinkedGeneration = FMemory.WriteGeneration);
        FLinked := False;
        if Success then
          FMemory.Write32(P, B);
        SetRegister(T, Ord(Success));
      end;
    49:
      begin
        var P := Address(Op);
        CheckAlignment(P, 3);
        FFPR[T] := FMemory.Read32(P);
      end;
    57:
      begin
        var P := Address(Op);
        CheckAlignment(P, 3);
        FMemory.Write32(P, FFPR[T]);
      end;
  else
    if not FVFPU.Execute(Op, FMemory, A) then
      Unsupported(Op);
  end;
end;

procedure TPSPCPU.Step;
begin
  if FHalted then
    Exit;
  FCurrentPC := FPC;
  CheckAlignment(FPC, 3);
  var Op := FMemory.ReadInstruction(FPC);
  FInDelay := FPendingDelay;
  FPendingDelay := False;
  FPC := FNextPC;
  FNextPC := Add32(FNextPC, 4);
  Execute(Op);
  FR[0] := 0;
  Inc(FInstructions);
end;

procedure TPSPCPU.Run(Budget: Cardinal);
begin
  FYielded := False;
  while (Budget <> 0) and not FHalted and not FYielded do
  begin
    Step;
    Dec(Budget);
  end;
end;

procedure TPSPCPU.Yield;
begin
  FYielded := True;
end;

procedure TPSPCPU.Halt;
begin
  FHalted := True;
end;

function TPSPCPU.SaveContext: TPSPCPUContext;
begin
  Result := Default(TPSPCPUContext);
  Move(FR, Result.R, SizeOf(FR));
  Move(FFPR, Result.FPR, SizeOf(FFPR));
  Result.FCR31 := FFCR31;
  Result.VFPU := FVFPU;
  Result.PC := FPC;
  Result.NextPC := FNextPC;
  Result.Hi := FHi;
  Result.Lo := FLo;
  Result.PendingDelay := FPendingDelay;
  Result.InDelay := FInDelay;
end;

procedure TPSPCPU.LoadContext(const Context: TPSPCPUContext);
begin
  FLinked := False;
  Move(Context.R, FR, SizeOf(FR));
  Move(Context.FPR, FFPR, SizeOf(FFPR));
  FFCR31 := Context.FCR31;
  FVFPU := Context.VFPU;
  FR[0] := 0;
  FPC := Context.PC;
  FNextPC := Context.NextPC;
  FHi := Context.Hi;
  FLo := Context.Lo;
  FPendingDelay := Context.PendingDelay;
  FInDelay := Context.InDelay;
  FHalted := False;
  FYielded := False;
end;

end.

