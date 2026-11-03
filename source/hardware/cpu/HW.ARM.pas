unit HW.ARM;

// Shared ARM/Thumb interpreter, barrel shifter and ARM7 multiply helpers.
// Platform cores provide the memory bus, BIOS callbacks and peripheral timing.

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots;

type
  TARMRead = function(Address: Cardinal; Size: Integer): Cardinal of object;

  TARMWrite = procedure(Address, Value: Cardinal; Size: Integer) of object;

  TARMCodePage = function(Address: Cardinal): PByte of object;

  TARMDataPage = function(Address: Cardinal; Writing: Boolean): PByte of object;

  TARMBusState = procedure(Sequential, Code: Boolean) of object;

  TARMIdle = procedure(Cycles: Integer) of object;

  TARMIRQSample = function: Boolean of object;

  TARMBusLock = procedure(Locked: Boolean) of object;

  TARMCheckpoint = record
    Registers: array[0..15] of Cardinal;
    Status, SavedStatus: Cardinal;
    Banked: array[0..5, 0..6] of Cardinal;
    Saved: array[0..5] of Cardinal;
    Pipeline: array[0..2] of Cardinal;
    PipelinePC, PipelineThumb: Cardinal;
    PipelineValid, FetchSequential: Boolean;
    Reserved: Word; // Preserve the zero padding in the snapshot layout.
    LDMGlitch: Integer;
  end;

  TSoftwareInterrupt = procedure(Number: Byte) of object;

  // Shared ARM/Thumb interpreter: ARM7TDMI by default, with ARMv5TE
  // decoding explicitly enabled for ARM946E-S users.
  TARMCPTransfer = function(Op: Cardinal; var Value: Cardinal): Boolean of object;

  TARMProcessor = class
  private
    const  // Bits 0..15 are EQ..NV for each CPSR NZCV nibble.
      Conditions: array[0..15] of Word = (
$56AA, $6A6A, $55A6, $6966, $66A9, $6A69, $66A5, $6A65,
$6A9A, $565A, $6996, $5556, $6A99, $6659, $6A95, $6655);
  private
    FRead: TARMRead;
    FReadCode: TARMRead;
    FCodePageRead: TARMCodePage;
    FCodeAccessFlag: PBoolean;
    FCodePage: PByte;
    FCodePageTag: Cardinal;
    FDataPageRead: TARMDataPage;
    FDataPageLimit: Cardinal;
    FDataPages: array[0..1, 0..7] of PByte;
    FDataPageTags: array[0..1, 0..7] of Cardinal;
    FReadUnrotated: TARMRead;
    FSWI: TSoftwareInterrupt;
    FWrite: TARMWrite;
    FBusState: TARMBusState;
    FIdle: TARMIdle;
    FIRQSample: TARMIRQSample;
    FBusLock: TARMBusLock;
    FARMv5: Boolean;
    FVectorBase: Cardinal;
    FCoprocessor: TARMCPTransfer;
    FPipeline: array[0..2] of Cardinal;
    FPipelinePC, FPipelineThumb: Cardinal;
    FPipelineValid, FFetchSequential, FDataSequential: Boolean;
    FBusCount, FInternalCycles: Integer;
    FReloadRequested, FGlitchOnComplete: Boolean;
    FLDMGlitch: Integer;
    FBankGeneration: UInt64;
    FBanked: array[0..5, 0..6] of Cardinal;
    FSaved: array[0..5] of Cardinal;
    procedure SetCodePageRead(const Value: TARMCodePage);
    procedure SetDataPageRead(const Value: TARMDataPage);
    function DataPage(Address: Cardinal; Writing: Boolean): PByte; inline;
    function DataRead(Address: Cardinal; Size: Integer; RotateValue: Boolean = True): Cardinal; inline;
    procedure DataWrite(Address, Value: Cardinal; Size: Integer); inline;
    function Fetch(Address: Cardinal; Size: Integer; Sequential: Boolean): Cardinal; inline;
    procedure Refill;
    function Reg(Index: Integer): Cardinal; inline;
    function StepARM(Op: Cardinal): Integer;
    function StepThumb(Op: Word): Integer;
    function StepARMv5(Op: Cardinal): Boolean;
    function StepTwoStage(IRQ: Boolean): Integer; inline;
    function AddFlags(A, B, Carry: Cardinal): Cardinal;
    procedure BranchExchange(Value: Cardinal);
    function Condition(Code: Integer): Boolean; inline;
    procedure SetPSR(Value: Cardinal);
    function SavedStatus: Cardinal; inline;
    procedure NZ(Value: Cardinal); inline;
    function Operand(Op: Cardinal; var Carry: Cardinal): Cardinal; inline;
    procedure ExceptionEntry(Mode: Integer; Vector: Cardinal);
  public
    R: array[0..15] of Cardinal;
    PSR, SPSR: Cardinal;
    constructor Create(Read: TARMRead; Write: TARMWrite);
    procedure Reset;
    procedure InvalidateInstructionPage;
    procedure InvalidateMemoryPages;
    function Step(IRQ: Boolean): Integer;
    procedure SetStatus(Value: Cardinal);
    procedure SerializeState(State: TStateArchive);
    procedure Capture(out State: TARMCheckpoint); inline;
    // Start Generation at zero; retain it with this processor and checkpoint.
    procedure CaptureCached(var State: TARMCheckpoint; var Generation: UInt64); inline;
    procedure Restore(const State: TARMCheckpoint);
    property BusState: TARMBusState read FBusState write FBusState;
    property Idle: TARMIdle read FIdle write FIdle;
    property IRQSample: TARMIRQSample read FIRQSample write FIRQSample;
    property BusLock: TARMBusLock read FBusLock write FBusLock;
    property SoftwareInterrupt: TSoftwareInterrupt read FSWI write FSWI;
    property MemoryRead: TARMRead read FRead write FRead;
    // Optional combined code-bus callback. Other buses retain separate
    // BusState/MemoryRead calls, including their exact access ordering.
    property MemoryReadCode: TARMRead read FReadCode write FReadCode;
    // Optional borrowed 16 KiB instruction page. The bus invalidates this
    // derived pointer when its mapping changes; fetched pipeline words survive.
    property InstructionPageRead: TARMCodePage read FCodePageRead write SetCodePageRead;
    property CodeAccessFlag: PBoolean read FCodeAccessFlag write FCodeAccessFlag;
    // Raw 4 KiB data pages only; side-effectful/unmapped regions return nil.
    // The bus calls InvalidateMemoryPages on TCM/WRAM remapping and state load.
    property MemoryPageRead: TARMDataPage read FDataPageRead write SetDataPageRead;
    property MemoryPageLimit: Cardinal read FDataPageLimit write FDataPageLimit;
    property MemoryReadUnrotated: TARMRead read FReadUnrotated write FReadUnrotated;
    property MemoryWrite: TARMWrite read FWrite write FWrite;
    property ARMv5: Boolean read FARMv5 write FARMv5;
    property VectorBase: Cardinal read FVectorBase write FVectorBase;
    property Coprocessor: TARMCPTransfer read FCoprocessor write FCoprocessor;
  end;

function ARMAdd(A, B: Cardinal): Cardinal; inline;

function ARMSub(A, B: Cardinal): Cardinal; inline;

// Shared barrel shifter: decoded immediate or low byte of a register.
// Carry supplies RRX/zero-shift input and receives the shifted-out bit.
function ARMRotateRight(Value: Cardinal; Count: Integer): Cardinal; inline;

function ARMShift(Value: Cardinal; Kind, Count: Integer; Immediate: Boolean; var Carry: Cardinal): Cardinal;

procedure ARM7MultiplyCarry(Multiplicand, Multiplier: Cardinal; Accumulator: UInt64; LongResult, SignedResult: Boolean; out Carry: Cardinal; out Cycles: Integer);

implementation

function ARMRotateRight(Value: Cardinal; Count: Integer): Cardinal; inline;
begin
  Count := Count and 31;
  if Count = 0 then
    Result := Value
  else
    Result := (Value shr Count) or (Value shl (32 - Count));
end;

function ARMShift(Value: Cardinal; Kind, Count: Integer; Immediate: Boolean; var Carry: Cardinal): Cardinal;
begin
  Result := Value;
  if (Count = 0) and not Immediate then
    Exit;

  case Kind of
    0:
      begin
        if Count = 0 then
          Exit;
        if Count <= 32 then
          Carry := (Value shr (32 - Count)) and 1
        else
          Carry := 0;
        if Count < 32 then
          Result := Value shl Count
        else
          Result := 0;
      end;
    1:
      begin
        if Count = 0 then
          Count := 32;
        if Count <= 32 then
          Carry := (Value shr (Count - 1)) and 1
        else
          Carry := 0;
        if Count < 32 then
          Result := Value shr Count
        else
          Result := 0;
      end;
    2:
      begin
        if Count = 0 then
          Count := 32;
        if Count < 32 then
        begin
          Carry := (Value shr (Count - 1)) and 1;
          Result := Value shr Count;
          if Value and $80000000 <> 0 then
            Result := Result or ($FFFFFFFF shl (32 - Count));
        end
        else
        begin
          Carry := Value shr 31;
          Result := 0;
          if Carry <> 0 then
            Result := $FFFFFFFF;
        end;
      end;
    3:
      begin
        if (Count = 0) and Immediate then
        begin
          Result := (Carry shl 31) or (Value shr 1);
          Carry := Value and 1;
        end
        else
        begin
          Result := ARMRotateRight(Value, Count);
          Carry := Result shr 31;
        end;
      end;
  end;
end;

type
  TPair = record
    Lo, Hi: UInt64;
  end;

function Bit(V: UInt64; N: Integer): UInt64; inline;
begin
  Result := (V shr N) and 1;
end;

function ROR128(V: TPair; N: Integer): TPair; inline;
begin
  Result.Lo := (V.Lo shr N) or (V.Hi shl (64 - N));
  Result.Hi := (V.Hi shr N) or (V.Lo shl (64 - N));
end;

procedure ARM7MultiplyCarry(Multiplicand, Multiplier: Cardinal; Accumulator: UInt64; LongResult, SignedResult: Boolean; out Carry: Cardinal; out Cycles: Integer);
const
  Correction: array[1..4] of Integer = (23, 15, 7, 31);
begin
  var M := UInt64(Multiplicand);
  var S := UInt64(Multiplier);
  if SignedResult then
  begin
    if M and $80000000 <> 0 then
      M := M or UInt64($300000000);
    if S and $80000000 <> 0 then
      S := S or UInt64($300000000);
  end;

  var Sum := Accumulator;
  var Car: UInt64 := 0;
  if S and 1 <> 0 then
    Car := not M;

  var AccShift := Accumulator shr 34;
  var Partial: TPair;
  Partial.Lo := Car and 1;
  Partial.Hi := 0;
  Sum := Sum shr 1;
  Car := Car shr 1;
  Partial := ROR128(Partial, 1);
  Cycles := 0;

  repeat
    var OutSum: UInt64 := 0;
    var OutCar: UInt64 := 0;
    for var i := 0 to 3 do
    begin
      var Addend: UInt64 := 0;
      var BoothCarry: UInt64 := 0;
      case (S shr (i * 2)) and 7 of
        1, 2:
          Addend := M;
        3:
          Addend := M shl 1;
        4:
          begin
            Addend := not (M shl 1);
            BoothCarry := 1;
          end;
        5, 6:
          begin
            Addend := not M;
            BoothCarry := 1;
          end;
      end;

      Addend := Addend and UInt64($3FFFFFFFF);
      Sum := Sum and UInt64($1FFFFFFFF);
      Car := Car and UInt64($1FFFFFFFF);
      var LowAddend := Addend and UInt64($1FFFFFFFF);
      var NextSum := Sum xor LowAddend xor Car;
      var NextCar := (((Sum and LowAddend) or (LowAddend and Car) or (Car and Sum)) shl 1) or BoothCarry;
      OutSum := OutSum or ((NextSum and 3) shl (i * 2));
      OutCar := OutCar or ((NextCar and 3) shl (i * 2));
      var Magic := Bit(AccShift, 0) + (1 - Bit(Car, 32)) + (1 - Bit(Addend, 33));
      Sum := (NextSum shr 2) or (Magic shl 31);
      Car := (NextCar shr 2) or ((1 - Bit(AccShift, 1)) shl 32);
      AccShift := AccShift shr 2;
    end;

    Sum := OutSum or (Sum shl 8);
    Car := OutCar or (Car shl 8);
    Partial.Lo := Partial.Lo or (Car and 255);
    Sum := Sum shr 8;
    Car := Car shr 8;
    Partial := ROR128(Partial, 8);
    if S and UInt64($100000000) <> 0 then
      S := (S shr 8) or UInt64($1FE000000)
    else
      S := S shr 8;
    S := S and UInt64($1FFFFFFFF);
    Inc(Cycles);
  until (S = 0) or (SignedResult and (S = UInt64($1FFFFFFFF)));

  Partial.Lo := Partial.Lo or Car;
  Partial := ROR128(Partial, Correction[Cycles]);

  if not LongResult and (Cycles = 4) then
    Carry := Cardinal(Bit(Partial.Hi, 31))
  else
    Carry := Cardinal(Bit(Partial.Hi, 63));
end;

function ARMMultiplyCycles(Multiplier: Cardinal; SignedResult: Boolean): Integer; inline;
begin
  // The Booth implementation consumes eight multiplier bits per iteration.
  // Its carry is needed only by ARM7 flag-setting multiplies; timing depends
  // solely on the remaining zero/sign-extended multiplier bytes.
  if SignedResult and (Multiplier and $80000000 <> 0) then
    Multiplier := not Multiplier;

  if Multiplier shr 8 = 0 then
    Exit(1);
  if Multiplier shr 16 = 0 then
    Exit(2);
  if Multiplier shr 24 = 0 then
    Exit(3);

  Result := 4;
end;

function ARMAdd(A, B: Cardinal): Cardinal;
begin
  {$IFOPT Q+}
  Result := Cardinal((UInt64(A) + B) and $FFFFFFFF);
  {$ELSE}
  Result := A + B;
  {$ENDIF}
end;

function ARMSub(A, B: Cardinal): Cardinal;
begin
  {$IFOPT Q+}
  Result := Cardinal((UInt64(A) + UInt64($100000000) - B) and $FFFFFFFF);
  {$ELSE}
  Result := A - B;
  {$ENDIF}
end;

function Bank(Mode: Cardinal): Integer; inline;
begin
  case Mode and 31 of
    $11:
      Result := 1;
    $12:
      Result := 2;
    $13:
      Result := 3;
    $17:
      Result := 4;
    $1B:
      Result := 5;
  else
    Result := 0;
  end;
end;

constructor TARMProcessor.Create(Read: TARMRead; Write: TARMWrite);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  FDataPageLimit := $FFFFFFFF;
  Reset;
end;

procedure TARMProcessor.Reset;
begin
  InvalidateMemoryPages;
  Inc(FBankGeneration);
  FillChar(R, SizeOf(R), 0);
  FillChar(FBanked, SizeOf(FBanked), 0);
  FillChar(FSaved, SizeOf(FSaved), 0);
  PSR := $D3;
  SPSR := 0;
  FLDMGlitch := 0;
  FPipelineValid := False;
  FFetchSequential := False;
  FDataSequential := False;
end;

function TARMProcessor.Reg(Index: Integer): Cardinal;
begin
  Result := R[Index];
  if (FLDMGlitch > 0) and (PSR and $20 = 0) and (Index in [8..14]) and (Bank(PSR) <> 0) and ((Index >= 13) or (Bank(PSR) = 1)) then
    Result := Result or FBanked[0, Index - 8];

  if Index = 15 then
    if PSR and $20 <> 0 then
      Result := ARMAdd(Result, 4)
    else
      Result := ARMAdd(Result, 8);
end;

function TARMProcessor.SavedStatus: Cardinal;
begin
  if Bank(PSR) = 0 then
    Result := PSR
  else
    Result := SPSR;
end;

procedure TARMProcessor.SetPSR(Value: Cardinal);
begin
  var StatusMask: Cardinal := $F00000FF;
  if FARMv5 then
    StatusMask := $F80000FF;
  Value := (Value and StatusMask) or $10;
  var Old := Bank(PSR and 31);
  var New := Bank(Value and 31);
  if Old <> New then
  begin
    Inc(FBankGeneration);
    var Start := 13;
    if (Old = 1) or (New = 1) then
      Start := 8;
    for var i := Start to 14 do
    begin
      var OldBank := Old;
      var NewBank := New;
      if i < 13 then
      begin
        if Old <> 1 then
          OldBank := 0;
        if New <> 1 then
          NewBank := 0;
      end;
      FBanked[OldBank, i - 8] := R[i];
      R[i] := FBanked[NewBank, i - 8];
    end;
    FSaved[Old] := SPSR;
    SPSR := FSaved[New];
  end;
  PSR := Value;
end;

procedure TARMProcessor.NZ(Value: Cardinal);
begin
  PSR := (PSR and $3FFFFFFF) or (Value and $80000000);
  if Value = 0 then
    PSR := PSR or $40000000;
end;

function TARMProcessor.Condition(Code: Integer): Boolean;
begin
  Result := Conditions[PSR shr 28] and (1 shl Code) <> 0;
end;

function TARMProcessor.Operand(Op: Cardinal; var Carry: Cardinal): Cardinal;
begin
  if Op and $02000000 <> 0 then
  begin
    var Count := Integer((Op shr 8) and 15) * 2;
    Result := ARMRotateRight(Op and 255, Count);
    if Count <> 0 then
      Carry := Result shr 31;
    Exit;
  end;

  var Value := Reg(Op and 15);
  if Op and $FF0 = 0 then
    Exit(Value);
  var Count := Integer((Op shr 7) and 31);
  var Immediate := Op and $10 = 0;
  if not Immediate then
  begin
    var RS := Integer((Op shr 8) and 15);
    Inc(FInternalCycles);
    Count := Integer(ARMAdd(Reg(RS), Cardinal(Ord(RS = 15) * 4)) and 255);
    if Op and 15 = 15 then
      Value := ARMAdd(Value, 4);
  end;
  Result := ARMShift(Value, (Op shr 5) and 3, Count, Immediate, Carry);
end;

procedure TARMProcessor.ExceptionEntry(Mode: Integer; Vector: Cardinal);
begin
  FReloadRequested := True;
  var Old := PSR;
  var ReturnAddress := ARMAdd(R[15], 4);
  SetPSR((PSR and $FFFFFFC0) or Cardinal(Mode) or $80);
  SPSR := Old;
  R[14] := ReturnAddress;
  R[15] := FVectorBase or Vector;
  if Mode = $11 then
    PSR := PSR or $40;
end;

function TARMProcessor.StepARMv5(Op: Cardinal): Boolean;

  function SignedWord(V: Cardinal): Int64;
  begin
    Result := V;
    if V and $80000000 <> 0 then
      Dec(Result, $100000000);
  end;

  function Half(V: Cardinal; Top: Boolean): Int64;
  begin
    if Top then
      V := V shr 16;
    Result := V and $FFFF;
    if Result >= $8000 then
      Dec(Result, $10000);
  end;

  function Saturate(V: Int64): Cardinal;
  begin
    if V > $7FFFFFFF then
    begin
      PSR := PSR or $08000000;
      Exit($7FFFFFFF);
    end;
    if V < -Int64($80000000) then
    begin
      PSR := PSR or $08000000;
      Exit($80000000);
    end;
    Result := Cardinal(V and $FFFFFFFF);
  end;

begin
  Result := True;
  var Next := ARMAdd(R[15], 4);
  var RD := Integer((Op shr 12) and 15);
  var RN := Integer((Op shr 16) and 15);
  var RM := Integer(Op and 15);
  if (Op and $0FFFFFF0 = $012FFF10) or (Op and $0FFFFFF0 = $012FFF30) then
  begin
    var Target := Reg(RM);
    if Op and $20 <> 0 then
      R[14] := Next;
    BranchExchange(Target);
    Exit;
  end
  else if Op and $0FFF0FF0 = $016F0F10 then
  begin
    var V := Reg(RM);
    var N := 0;
    while (N < 32) and (V and $80000000 = 0) do
    begin
      Inc(N);
      V := V shl 1;
    end;
    R[RD] := N;
  end
  else if Op and $0F9000F0 = $01000050 then
  begin
    var Kind := (Op shr 21) and 3;
    var B := SignedWord(Reg(RN));
    if Kind >= 2 then
      B := SignedWord(Saturate(B * 2));
    var A := SignedWord(Reg(RM));
    if Kind and 1 <> 0 then
      R[RD] := Saturate(A - B)
    else
      R[RD] := Saturate(A + B);
  end
  else if Op and $0F900090 = $01000080 then
  begin
    var Kind := (Op shr 21) and 3;
    var RS := Integer((Op shr 8) and 15);
    var Product := Half(Reg(RM), Op and $20 <> 0) * Half(Reg(RS), Op and $40 <> 0);
    case Kind of
      0:
        begin
          var Sum := Product + SignedWord(Reg(RD));
          if (Sum > $7FFFFFFF) or (Sum < -Int64($80000000)) then
            PSR := PSR or $08000000;
          R[RN] := Cardinal(Sum and $FFFFFFFF);
        end;
      1:
        begin
          Product := SignedWord(Reg(RM)) * Half(Reg(RS), Op and $40 <> 0);
          // Arithmetic shift right by 16, including negative fractional products.
          if Product < 0 then
            Product := -((-Product + $FFFF) div $10000)
          else
            Product := Product div $10000;
          if Op and $20 = 0 then
          begin
            Product := Product + SignedWord(Reg(RD));
            if (Product > $7FFFFFFF) or (Product < -Int64($80000000)) then
              PSR := PSR or $08000000;
          end;
          R[RN] := Cardinal(Product and $FFFFFFFF);
        end;
      2:
        begin
          var LowSum := UInt64(R[RD]) + UInt64(Product and $FFFFFFFF);
          var HighSum := UInt64(R[RN]) + Cardinal(UInt64(Product) shr 32) + (LowSum shr 32);
          R[RD] := Cardinal(LowSum and $FFFFFFFF);
          R[RN] := Cardinal(HighSum and $FFFFFFFF);
        end;
      3:
        R[RN] := Cardinal(Product and $FFFFFFFF);
    end;
  end
  else if (Op and $0E1000D0 = $000000D0) then
  begin
    // ARMv5 LDRD/STRD occupy the ARM7's unused signed-store encodings.
    if (RD and 1 <> 0) or (RD >= 14) then
    begin
      ExceptionEntry($1B, 4);
      R[14] := Next;
      Exit;
    end;
    var Offset := Reg(RM);
    if Op and $00400000 <> 0 then
      Offset := ((Op shr 4) and $F0) or (Op and 15);
    var Base := Reg(RN);
    var Adjusted := ARMAdd(Base, Offset);
    if Op and $00800000 = 0 then
      Adjusted := ARMSub(Base, Offset);
    var Address := Adjusted;
    if Op and $01000000 = 0 then
      Address := Base;
    if Op and $20 = 0 then
    begin
      R[RD] := DataRead(Address, 4, False);
      R[RD + 1] := DataRead(ARMAdd(Address, 4), 4, False);
    end
    else
    begin
      DataWrite(Address, R[RD], 4);
      DataWrite(ARMAdd(Address, 4), R[RD + 1], 4);
    end;
    if (Op and $01000000 = 0) or (Op and $00200000 <> 0) then
      R[RN] := Adjusted;
  end
  else if Op and $0FF000F0 = $01200070 then
  begin
    ExceptionEntry($17, $0C);
    R[14] := Next;
    Exit;
  end
  else
    Exit(False);

  R[15] := Next;
end;

function TARMProcessor.StepARM(Op: Cardinal): Integer;
begin
  Result := 1;
  var PC := R[15];
  if FARMv5 and (Op shr 28 = 15) then
  begin
    // BLX immediate and PLD occupy the unconditional ARMv5 encoding space.
    if Op and $FE000000 = $FA000000 then
    begin
      var Offset := Int64(Op and $FFFFFF) * 4 + ((Op shr 23) and 2);
      if Op and $800000 <> 0 then
        Dec(Offset, $4000000);
      R[14] := ARMAdd(PC, 4);
      BranchExchange(Cardinal((Int64(PC) + 8 + Offset) and $FFFFFFFF) or 1);
    end
    else if Op and $0D70F000 = $0550F000 then
      R[15] := ARMAdd(PC, 4)
    else
      ExceptionEntry($1B, 4);
    Exit(3);
  end;
  if (Op shr 28 <> 14) and not Condition(Op shr 28) then
  begin
    R[15] := ARMAdd(PC, 4);
    Exit;
  end;

  // Ordinary non-flag ALU operations need no extended-opcode decoding,
  // shifter carry or wide flag arithmetic. Keep PC destinations, shifted
  // operands and the status-register encodings on the complete path below.
  if ((Op shr 12) and 15 <> 15) and ((Op and $0E100000 = $02000000) or (Op and $0E100FF0 = 0)) then
  begin
    var SimpleKind := (Op shr 21) and 15;
    if (SimpleKind < 8) or (SimpleKind > 11) then
    begin
      var A := Reg((Op shr 16) and 15);
      var B: Cardinal;
      if Op and $02000000 <> 0 then
        B := ARMRotateRight(Op and 255, Integer((Op shr 8) and 15) * 2)
      else
        B := Reg(Op and 15);
      var Value: Cardinal := 0;
      case SimpleKind of
        0:
          Value := A and B;
        1:
          Value := A xor B;
        2:
          Value := ARMSub(A, B);
        3:
          Value := ARMSub(B, A);
        4:
          Value := ARMAdd(A, B);
        5:
          Value := ARMAdd(ARMAdd(A, B), (PSR shr 29) and 1);
        6:
          Value := ARMAdd(ARMAdd(A, not B), (PSR shr 29) and 1);
        7:
          Value := ARMAdd(ARMAdd(B, not A), (PSR shr 29) and 1);
        12:
          Value := A or B;
        13:
          Value := B;
        14:
          Value := A and not B;
        15:
          Value := not B;
      end;
      R[(Op shr 12) and 15] := Value;
      R[15] := ARMAdd(PC, 4);
      Exit;
    end;
  end;

  var Next := ARMAdd(PC, 4);
  var RD := Integer((Op shr 12) and 15);
  var RN := Integer((Op shr 16) and 15);
  var Load := Op and $00100000 <> 0;
  var Carry: Cardinal := (PSR shr 29) and 1;
  if FARMv5 and ((Op and $0F900000 = $01000000) or (Op and $0E1000D0 = $000000D0)) and StepARMv5(Op) then
    Exit(3);

  if Op and $0F000000 = $0F000000 then
  begin
    R[15] := Next;
    if Assigned(FSWI) then
      FSWI(Byte((Op shr 16) and 255))
    else
    begin
      ExceptionEntry($13, 8);
      R[14] := Next;
    end;
    Exit(3);
  end;

  // ARM7 decodes BX using only the dispatch bits, including undocumented masks.
  if Op and $0F900090 = $01000010 then
  begin
    var Value := Reg(Op and 15);
    var Mask: Cardinal := 0;
    var ToSaved := Op and $00400000 <> 0;
    if RN and 9 = 9 then
    begin
      if ToSaved then
      begin
        if Bank(PSR) <> 0 then
          SPSR := (SPSR and not $20) or ((Value and 1) shl 5);
      end
      else
        PSR := (PSR and not $20) or ((Value and 1) shl 5);
    end
    else
    begin
      if RN and 8 <> 0 then
        Mask := Mask or $F0000000;
      if RN and 1 <> 0 then
        Mask := Mask or $FF;
      if ToSaved then
      begin
        if Bank(PSR) <> 0 then
          SPSR := ((SPSR and not Mask) or (Value and Mask)) and $F00000FF;
      end
      else
      begin
        if PSR and 31 = $10 then
          Mask := Mask and $F0000000;
        SetPSR((PSR and not Mask) or (Value and Mask));
      end;
    end;

    if RD = 15 then
    begin
      BranchExchange((Value and not Cardinal(1)) or ((PSR shr 5) and 1));
      Exit(3);
    end;

    R[RD] := Value;
    R[15] := Next;
    Exit(1);
  end;

  if Op and $0E000000 = $0A000000 then
  begin
    FReloadRequested := True;
    if Op and $01000000 <> 0 then
      R[14] := Next;
    var Offset := Int64(Op and $FFFFFF) * 4;
    if Op and $800000 <> 0 then
      Dec(Offset, $4000000);
    Next := Cardinal((Int64(PC) + 8 + Offset + $100000000) and $FFFFFFFF);
    Result := 3;
  end
  else if Op and $0E000000 = $08000000 then
  begin
    var List := Op and $FFFF;
    var Count := 0;
    for var i := 0 to 15 do
      if List and (1 shl i) <> 0 then
        Inc(Count);
    var EmptyList := Count = 0;
    if EmptyList then
    begin
      List := $8000;
      Count := 16;
    end;

    var Base := Reg(RN);
    var Address := Base;
    var Up := Op and $00800000 <> 0;
    var Before := Op and $01000000 <> 0;
    if Up then
    begin
      if Before then
        Address := ARMAdd(Base, 4);
    end
    else
    begin
      Address := ARMSub(Base, Count * 4);
      if not Before then
        Address := ARMAdd(Address, 4);
    end;
    var Writeback: Cardinal;
    if Up then
      Writeback := ARMAdd(Base, Count * 4)
    else
      Writeback := ARMSub(Base, Count * 4);
    var First := True;
    var OldStatus := PSR;
    var UserBank := (Op and $00400000 <> 0) and not (Load and (List and $8000 <> 0));
    if Load and (Op and $00200000 <> 0) then
      R[RN] := Writeback;
    if UserBank then
      SetPSR((PSR and not Cardinal(31)) or $10);
    for var i := 0 to 15 do
      if List and (1 shl i) <> 0 then
      begin
        if not Load then
        begin
          var V := Reg(i);
          if i = 15 then
            V := ARMAdd(V, 4);
          DataWrite(Address, V, 4);
        end;
        if First and (Op and $00200000 <> 0) then
          R[RN] := Writeback;
        if Load then
        begin
          var V := DataRead(Address, 4, False);
          if i = 15 then
          begin
            Next := V and $FFFFFFFC;
            if FARMv5 and (Op and $00400000 = 0) then
            begin
              PSR := (PSR and not Cardinal($20)) or ((V and 1) shl 5);
              if V and 1 <> 0 then
                Next := V and $FFFFFFFE;
            end;
            FReloadRequested := True;
          end
          else
            R[i] := V;
        end;
        FDataSequential := True;
        First := False;
        Address := ARMAdd(Address, 4);
      end;
    if UserBank then
      SetPSR(OldStatus);
    if Load and (Op and $00400000 <> 0) then
    begin
      if List and $8000 <> 0 then
        SetPSR(SavedStatus);
      FGlitchOnComplete := not FARMv5;
    end;
    if Load then
      Inc(FInternalCycles);
    Result := 1 + Count + Ord(Load);
  end
  else if Op and $0C000000 = $04000000 then
  begin
    var Offset := Op and $FFF;
    if Op and $02000000 <> 0 then
      Offset := ARMShift(Reg(Op and 15), (Op shr 5) and 3, (Op shr 7) and 31, True, Carry);
    var Base := Reg(RN);
    var Adjusted: Cardinal;
    if Op and $00800000 <> 0 then
      Adjusted := ARMAdd(Base, Offset)
    else
      Adjusted := ARMSub(Base, Offset);
    var Address := Adjusted;
    if Op and $01000000 = 0 then
      Address := Base;
    var Size := 4;
    if Op and $00400000 <> 0 then
      Size := 1;
    if Load then
    begin
      Inc(FInternalCycles);
      var Value := DataRead(Address, Size);
      if RD = 15 then
      begin
        Next := Value and $FFFFFFFC;
        if FARMv5 then
        begin
          PSR := (PSR and not Cardinal($20)) or ((Value and 1) shl 5);
          if Value and 1 <> 0 then
            Next := Value and $FFFFFFFE;
        end;
        FReloadRequested := True;
      end
      else
        R[RD] := Value;
    end
    else
    begin
      var Value := Reg(RD);
      if RD = 15 then
        Value := ARMAdd(Value, 4);
      DataWrite(Address, Value, Size);
    end;
    if ((Op and $00200000 <> 0) or (Op and $01000000 = 0)) and (not Load or (RD <> RN)) then
      R[RN] := Adjusted;
    Result := 2 + Ord(Load);
  end
  else if Op and $0FBF0FFF = $010F0000 then
  begin
    var V := PSR;
    if Op and $00400000 <> 0 then
      V := SavedStatus;
    R[RD] := V;
  end
  else if Op and $0DB0F000 = $0120F000 then
  begin
    var V := Operand(Op, Carry);
    var Mask: Cardinal := 0;
    if Op and $00010000 <> 0 then
      Mask := Mask or $FF;
    if Op and $00080000 <> 0 then
      if FARMv5 then
        Mask := Mask or $F8000000
      else
        Mask := Mask or $F0000000;
    if Op and $00400000 <> 0 then
    begin
      if Bank(PSR) <> 0 then
        if FARMv5 then
          SPSR := ((SPSR and not Mask) or (V and Mask)) and $F80000FF
        else
          SPSR := ((SPSR and not Mask) or (V and Mask)) and $F00000FF;
    end
    else
    begin
      if PSR and 31 = $10 then
        Mask := Mask and $FF000000;
      SetPSR((PSR and not Mask) or (V and Mask));
    end;
  end
  else if Op and $0FC000F0 = $00000090 then
  begin
    var RM := Integer(Op and 15);
    var RS := Integer((Op shr 8) and 15);
    var Dest := Integer((Op shr 16) and 15);
    var MultiplyM := Reg(RM);
    var MultiplyS := Reg(RS);
    var Acc: UInt64 := 0;
    if Op and $00200000 <> 0 then
      Acc := Reg(RD);
    var MultiplyCarry: Cardinal;
    var MultiplyClocks: Integer;
    if FARMv5 or not Load then
    begin
      MultiplyCarry := 0;
      MultiplyClocks := ARMMultiplyCycles(MultiplyS, True);
    end
    else
      ARM7MultiplyCarry(MultiplyM, MultiplyS, Acc, False, True, MultiplyCarry, MultiplyClocks);
    var V := UInt64(MultiplyM) * MultiplyS;
    if Op and $00200000 <> 0 then
      V := V + Reg(RD);
    R[Dest] := Cardinal(V and $FFFFFFFF);
    if Load then
    begin
      NZ(R[Dest]);
      if not FARMv5 then
        PSR := (PSR and $DFFFFFFF) or (MultiplyCarry shl 29);
    end;
    Inc(FInternalCycles, MultiplyClocks + Ord(Op and $00200000 <> 0));
    Result := 1 + FInternalCycles;
  end
  else if Op and $0F8000F0 = $00800090 then
  begin
    var RM := Reg(Op and 15);
    var RS := Reg((Op shr 8) and 15);
    var Acc: UInt64 := 0;
    if Op and $00200000 <> 0 then
      Acc := (UInt64(R[RN]) shl 32) or R[RD];
    var MultiplyCarry: Cardinal;
    var MultiplyClocks: Integer;
    if FARMv5 or not Load then
    begin
      MultiplyCarry := 0;
      MultiplyClocks := ARMMultiplyCycles(RS, Op and $00400000 <> 0);
    end
    else
      ARM7MultiplyCarry(RM, RS, Acc, True, Op and $00400000 <> 0, MultiplyCarry, MultiplyClocks);
    var V: UInt64;
    if Op and $00400000 <> 0 then
    begin
      var M := Int64(RM);
      if RM and $80000000 <> 0 then
        Dec(M, $100000000);
      var S := Int64(RS);
      if RS and $80000000 <> 0 then
        Dec(S, $100000000);
      var SignedProduct := M * S;
      if SignedProduct < 0 then
        V := (not UInt64(-SignedProduct)) + 1
      else
        V := UInt64(SignedProduct);
    end
    else
      V := UInt64(RM) * RS;
    if Op and $00200000 <> 0 then
    begin
      var Prior := UInt64(R[RN]) shl 32 or R[RD];
      var Lo := UInt64(Cardinal(V and $FFFFFFFF)) + Cardinal(Prior and $FFFFFFFF);
      var Hi := (V shr 32) + (Prior shr 32) + (Lo shr 32);
      V := ((Hi and $FFFFFFFF) shl 32) or (Lo and $FFFFFFFF);
    end;
    R[RD] := Cardinal(V and $FFFFFFFF);
    R[RN] := Cardinal(V shr 32);
    if Load then
    begin
      var SavedCarry := PSR and $20000000;
      PSR := (PSR and $1FFFFFFF) or (R[RN] and $80000000);
      if FARMv5 then
        PSR := PSR or SavedCarry
      else
        PSR := PSR or (MultiplyCarry shl 29);
      if V = 0 then
        PSR := PSR or $40000000;
    end;
    Inc(FInternalCycles, 1 + MultiplyClocks + Ord(Op and $00200000 <> 0));
    Result := 1 + FInternalCycles;
  end
  else if Op and $0FB00FF0 = $01000090 then
  begin
    var Size := 4;
    if Op and $00400000 <> 0 then
      Size := 1;
    var Address := Reg(RN);
    var Old: Cardinal;
    if Assigned(FBusLock) then
      FBusLock(True);
    try
      Old := DataRead(Address, Size);
      DataWrite(Address, Reg(Op and 15), Size);
    finally
      if Assigned(FBusLock) then
        FBusLock(False);
    end;
    R[RD] := Old;
    Inc(FInternalCycles);
    Result := 4;
  end
  else if (Op and $0E000090 = $00000090) and (Op and $60 <> 0) then
  begin
    var Offset: Cardinal;
    if Op and $00400000 <> 0 then
      Offset := ((Op shr 4) and $F0) or (Op and 15)
    else
      Offset := Reg(Op and 15);
    var Base := Reg(RN);
    var Adjusted: Cardinal;
    if Op and $00800000 <> 0 then
      Adjusted := ARMAdd(Base, Offset)
    else
      Adjusted := ARMSub(Base, Offset);
    var Address := Adjusted;
    if Op and $01000000 = 0 then
      Address := Base;
    var Kind := (Op shr 5) and 3;
    if Load then
    begin
      Inc(FInternalCycles);
      var Size := 2;
      if Kind = 2 then
        Size := 1;
      if (Kind = 3) and (Address and 1 <> 0) then
      begin
        Size := 1;
        Kind := 2;
      end;
      var V := DataRead(Address, Size);
      if Kind = 2 then
      begin
        if V and $80 <> 0 then
          V := V or $FFFFFF00;
      end
      else if Kind = 3 then
        if V and $8000 <> 0 then
          V := V or $FFFF0000;
      if RD = 15 then
      begin
        Next := V and $FFFFFFFC;
        FReloadRequested := True;
      end
      else
        R[RD] := V;
    end
    else
    begin
      var V := Reg(RD);
      if RD = 15 then
        V := ARMAdd(V, 4);
      var Size := 2;
      if Kind = 2 then
        Size := 1;
      DataWrite(Address, V, Size);
    end;
    if ((Op and $00200000 <> 0) or (Op and $01000000 = 0)) and (not Load or (RD <> RN)) then
      R[RN] := Adjusted;
    Result := 2 + Ord(Load);
  end
  else if Op and $0F000010 = $0E000010 then
  begin
    if FARMv5 and Assigned(FCoprocessor) then
    begin
      var Value := Reg(RD);
      if FCoprocessor(Op, Value) then
      begin
        if Load then
          if RD = 15 then
            PSR := (PSR and $0FFFFFFF) or (Value and $F0000000)
          else
            R[RD] := Value;
        R[15] := Next;
        Exit(2);
      end;
    end;

    if (Op shr 8) and 15 <> 14 then
    begin
      ExceptionEntry($1B, 4);
      R[14] := Next;
      Exit(3);
    end;

    if Load then
    begin
      var Value := DataRead($FFFFFFFC, 4);
      if RD = 15 then
        PSR := (PSR and $0FFFFFFF) or (Value and $F0000000)
      else
        R[RD] := Value;
    end
    else
      DataWrite($FFFFFFFF, R[RD], 4);
    Inc(FInternalCycles);
  end
  else if Op and $0C000000 = 0 then
  begin
    var Kind := (Op shr 21) and 15;
    var V1 := Reg(RN);
    if (RN = 15) and (Op and $02000010 = $10) then
      V1 := ARMAdd(V1, 4);
    var V2 := Operand(Op, Carry);
    if Op and $02000010 = $10 then
      Result := 2;
    var V: Cardinal := 0;
    var Arithmetic := (((Kind >= 2) and (Kind <= 7)) or (Kind = 10) or (Kind = 11));
    var Sum: UInt64 := 0;
    case Kind of
      0, 8:
        V := V1 and V2;
      1, 9:
        V := V1 xor V2;
      2, 10:
        Sum := UInt64(V1) + (V2 xor $FFFFFFFF) + 1;
      3:
        Sum := UInt64(V2) + (V1 xor $FFFFFFFF) + 1;
      4, 11:
        Sum := UInt64(V1) + V2;
      5:
        Sum := UInt64(V1) + V2 + ((PSR shr 29) and 1);
      6:
        Sum := UInt64(V1) + (V2 xor $FFFFFFFF) + ((PSR shr 29) and 1);
      7:
        Sum := UInt64(V2) + (V1 xor $FFFFFFFF) + ((PSR shr 29) and 1);
      12:
        V := V1 or V2;
      13:
        V := V2;
      14:
        V := V1 and not V2;
      15:
        V := not V2;
    end;
    if Arithmetic then
      V := Cardinal(Sum and $FFFFFFFF);
    var SetFlags := Load or (((Kind >= 8) and (Kind <= 11)));
    if SetFlags then
    begin
      NZ(V);
      if Arithmetic then
      begin
        var B := V2;
        var AA := V1;
        if ((Kind = 3) or (Kind = 7)) then
        begin
          AA := V2;
          B := V1;
        end;
        var Overflow: Boolean;
        if ((Kind = 2) or (Kind = 3) or (Kind = 6) or (Kind = 7) or (Kind = 10)) then
          Overflow := (AA xor B) and (AA xor V) and $80000000 <> 0
        else
          Overflow := (not (AA xor B)) and (AA xor V) and $80000000 <> 0;
        PSR := (PSR and $CFFFFFFF) or (Cardinal(Ord(Sum > $FFFFFFFF)) shl 29) or (Cardinal(Ord(Overflow)) shl 28);
      end
      else
        PSR := (PSR and $DFFFFFFF) or (Carry shl 29);
    end;
    if not (((Kind >= 8) and (Kind <= 11))) then
      if RD = 15 then
      begin
        FReloadRequested := True;
        Next := V and $FFFFFFFC;
        if SetFlags then
          SetPSR(SavedStatus);
        if PSR and $20 <> 0 then
          Next := V and $FFFFFFFE;
        Result := 3;
      end
      else
        R[RD] := V;

    // The ARM7 status restore also applies to test/compare encodings with
    // Rd=15. They leave the PC pipeline intact because no result is written.
    if (Kind in [8..11]) and (RD = 15) and Load then
      SetPSR(SavedStatus);
  end
  else
  begin
    ExceptionEntry($1B, 4);
    R[14] := Next;
    Exit(3);
  end;

  R[15] := Next;
end;

procedure TARMProcessor.SetStatus(Value: Cardinal);
begin
  SetPSR(Value);
end;

procedure TARMProcessor.BranchExchange(Value: Cardinal);
begin
  FReloadRequested := True;
  PSR := (PSR and not $20) or ((Value and 1) shl 5);
  if PSR and $20 <> 0 then
    R[15] := Value and $FFFFFFFE
  else
    R[15] := Value and $FFFFFFFC;
end;

function TARMProcessor.AddFlags(A, B, Carry: Cardinal): Cardinal;
begin
  var Sum := UInt64(A) + B + Carry;
  Result := Cardinal(Sum and $FFFFFFFF);
  NZ(Result);
  var Overflow := (not (A xor B)) and (A xor Result) and $80000000 <> 0;
  PSR := (PSR and $CFFFFFFF) or (Cardinal(Ord(Sum > $FFFFFFFF)) shl 29) or
    (Cardinal(Ord(Overflow)) shl 28);
end;

procedure TARMProcessor.InvalidateInstructionPage;
begin
  FCodePageTag := $FFFFFFFF;
  FCodePage := nil;
end;

procedure TARMProcessor.SetCodePageRead(const Value: TARMCodePage);
begin
  FCodePageRead := Value;
  InvalidateInstructionPage;
end;

procedure TARMProcessor.InvalidateMemoryPages;
begin
  InvalidateInstructionPage;
  FillChar(FDataPages, SizeOf(FDataPages), 0);
  FillChar(FDataPageTags, SizeOf(FDataPageTags), $FF);
end;

procedure TARMProcessor.SetDataPageRead(const Value: TARMDataPage);
begin
  FDataPageRead := Value;
  InvalidateMemoryPages;
end;

function TARMProcessor.DataPage(Address: Cardinal; Writing: Boolean): PByte;
begin
  var Page := Address and $FFFFF000;
  var Index := (Address shr 12) and 7;
  if FDataPageTags[Ord(Writing), Index] <> Page then
  begin
    FDataPages[Ord(Writing), Index] := FDataPageRead(Page, Writing);
    if FDataPages[Ord(Writing), Index] <> nil then
      FDataPageTags[Ord(Writing), Index] := Page
    else
      FDataPageTags[Ord(Writing), Index] := $FFFFFFFF;
  end;
  Result := FDataPages[Ord(Writing), Index];
end;

function TARMProcessor.Fetch(Address: Cardinal; Size: Integer; Sequential: Boolean): Cardinal;
begin
  if FLDMGlitch > 0 then
    Dec(FLDMGlitch);
  if Assigned(FReadCode) then
  begin
    var Memory: PByte := nil;
    if Assigned(FCodePageRead) then
    begin
      if FCodeAccessFlag <> nil then
        FCodeAccessFlag^ := True;
      var Page := Address and $FFFFC000;
      if FCodePageTag <> Page then
      begin
        FCodePage := FCodePageRead(Page);
        if FCodePage <> nil then
          FCodePageTag := Page
        else
          FCodePageTag := $FFFFFFFF;
      end;
      Memory := FCodePage;
    end;
    if Memory <> nil then
    begin
      Inc(Memory, Address and $3FFF);
      if Size = 4 then
        Result := PCardinal(Memory)^
      else
        Result := PWord(Memory)^;
    end
    else
      Result := FReadCode(Address, Size);
  end
  else
  begin
    if Assigned(FBusState) then
      FBusState(Sequential, True);
    Result := FRead(Address, Size);
  end;
  Inc(FBusCount);
end;

function TARMProcessor.DataRead(Address: Cardinal; Size: Integer; RotateValue: Boolean): Cardinal;
begin
  if FLDMGlitch > 0 then
    Dec(FLDMGlitch);
  if Assigned(FBusState) then
    FBusState(FDataSequential, False);
  FFetchSequential := False;
  var Memory: PByte := nil;
  if Assigned(FDataPageRead) and (Address < FDataPageLimit) then
  begin
    if FCodeAccessFlag <> nil then
      FCodeAccessFlag^ := False;
    Memory := DataPage(Address, False);
  end;
  if Memory <> nil then
  begin
    Inc(Memory, (Address and $FFF) and not Cardinal(Size - 1));
    case Size of
      1:
        Result := Memory^;
      2:
        Result := PWord(Memory)^;
    else
      Result := PCardinal(Memory)^;
    end;
    if RotateValue and (Size = 4) and (Address and 3 <> 0) then
      Result := ARMRotateRight(Result, Integer(Address and 3) * 8);
  end
  else if RotateValue then
    Result := FRead(Address, Size)
  else if Assigned(FReadUnrotated) then
    Result := FReadUnrotated(Address, Size)
  else
    Result := FRead(Address and not Cardinal(Size - 1), Size);
  Inc(FBusCount);
end;

procedure TARMProcessor.DataWrite(Address, Value: Cardinal; Size: Integer);
begin
  if FLDMGlitch > 0 then
    Dec(FLDMGlitch);
  if Assigned(FBusState) then
    FBusState(FDataSequential, False);
  FFetchSequential := False;
  var Memory: PByte := nil;
  if Assigned(FDataPageRead) and (Address < FDataPageLimit) then
  begin
    if FCodeAccessFlag <> nil then
      FCodeAccessFlag^ := False;
    Memory := DataPage(Address, True);
  end;
  if Memory <> nil then
  begin
    Inc(Memory, (Address and $FFF) and not Cardinal(Size - 1));
    case Size of
      1:
        Memory^ := Byte(Value);
      2:
        PWord(Memory)^ := Word(Value);
      4:
        PCardinal(Memory)^ := Value;
    end;
  end
  else
    FWrite(Address, Value, Size);
  Inc(FBusCount);
end;

procedure TARMProcessor.Refill;
begin
  var Size := 4;
  if PSR and $20 <> 0 then
    Size := 2;
  R[15] := R[15] and not Cardinal(Size - 1);
  FPipelinePC := R[15];
  FPipelineThumb := PSR and $20;
  FPipeline[0] := Fetch(R[15], Size, False);
  FPipeline[1] := Fetch(ARMAdd(R[15], Size), Size, True);
  if Assigned(FIRQSample) then
    FPipeline[2] := Fetch(ARMAdd(R[15], Size * 2), Size, True);
  FPipelineValid := True;
  FFetchSequential := True;
end;

function TARMProcessor.StepTwoStage(IRQ: Boolean): Integer;
begin
  FBusCount := 0;
  FInternalCycles := 0;
  FReloadRequested := False;
  FGlitchOnComplete := False;
  FDataSequential := False;
  if not FPipelineValid or (FPipelinePC <> R[15]) or (FPipelineThumb <> PSR and $20) then
    Refill;
  var Op := FPipeline[0];
  var PC := R[15];
  var Thumb := PSR and $20;
  var Size := 4;
  if Thumb <> 0 then
    Size := 2;
  var ColdCycles := FBusCount;
  FBusCount := 0;
  FPipeline[0] := FPipeline[1];
  FPipeline[1] := Fetch(ARMAdd(PC, Size * 2), Size, FFetchSequential);
  FFetchSequential := True;
  if IRQ and (PSR and $80 = 0) then
    ExceptionEntry($12, $18)
  else if Thumb <> 0 then
    StepThumb(Word(Op))
  else
    StepARM(Op);
  if FInternalCycles > 0 then
  begin
    FFetchSequential := False;
    FLDMGlitch := Max(0, FLDMGlitch - FInternalCycles);
    if Assigned(FIdle) then
      FIdle(FInternalCycles);
  end;
  if FGlitchOnComplete then
    FLDMGlitch := 2;
  if FReloadRequested or (R[15] <> ARMAdd(PC, Size)) or (PSR and $20 <> Thumb) then
    Refill
  else
    FPipelinePC := R[15];
  Result := ColdCycles + FBusCount + FInternalCycles;
end;

function TARMProcessor.Step(IRQ: Boolean): Integer;
begin
  if not Assigned(FIRQSample) then
    Exit(StepTwoStage(IRQ));

  FBusCount := 0;
  FInternalCycles := 0;
  FReloadRequested := False;
  FGlitchOnComplete := False;
  FDataSequential := False;
  if not FPipelineValid or (FPipelinePC <> R[15]) or (FPipelineThumb <> PSR and $20) then
    Refill;

  // Execute, decode and fetch opcodes survive RAM writes until a refill.
  var Op := FPipeline[0];
  var PC := R[15];
  var Thumb := PSR and $20;
  var Size := 4;
  if Thumb <> 0 then
    Size := 2;
  var ColdCycles := FBusCount;
  FBusCount := 0;
  if not Assigned(FIRQSample) then
  begin
    FPipeline[0] := FPipeline[1];
    FPipeline[1] := Fetch(ARMAdd(PC, Size * 2), Size, FFetchSequential);
    FFetchSequential := True;
  end;
  if not Assigned(FIRQSample) and IRQ and (PSR and $80 = 0) then
  begin
    ExceptionEntry($12, $18);
  end
  else if Thumb <> 0 then
    StepThumb(Word(Op))
  else
    StepARM(Op);
  if FInternalCycles > 0 then
  begin
    FFetchSequential := False;
    FLDMGlitch := Max(0, FLDMGlitch - FInternalCycles);
    if Assigned(FIdle) then
      FIdle(FInternalCycles);
  end;
  if FGlitchOnComplete then
    FLDMGlitch := 2;
  if Assigned(FIRQSample) then
  begin
    if FReloadRequested or (R[15] <> ARMAdd(PC, Size)) or (PSR and $20 <> Thumb) then
    begin
      // Refill's first two reads belong to the branch instruction; its last
      // read advances the pipeline for the instruction at the target.
      var NewSize := 4;
      if PSR and $20 <> 0 then
        NewSize := 2;
      FPipelinePC := R[15] and not Cardinal(NewSize - 1);
      R[15] := FPipelinePC;
      FPipelineThumb := PSR and $20;
      FPipeline[0] := Fetch(R[15], NewSize, False);
      FPipeline[1] := Fetch(ARMAdd(R[15], NewSize), NewSize, True);
      FPipelineValid := True;
      FFetchSequential := True;
    end
    else
    begin
      FPipeline[0] := FPipeline[1];
      FPipeline[1] := FPipeline[2];
      FPipelinePC := R[15];
    end;

    // Keep the fetch-stage opcode separate from decode and execute. IRQ is
    // sampled on the last instruction access, before pipeline advancement.
    var PendingIRQ := FIRQSample() and (PSR and $80 = 0);
    var NewSize := 4;
    if PSR and $20 <> 0 then
      NewSize := 2;
    FPipeline[2] := Fetch(ARMAdd(R[15], NewSize * 2), NewSize, FFetchSequential);
    FFetchSequential := True;
    if PendingIRQ then
    begin
      ExceptionEntry($12, $18);
      Refill;
    end;
  end;
  if not Assigned(FIRQSample) then
    if FReloadRequested or (R[15] <> ARMAdd(PC, Size)) or (PSR and $20 <> Thumb) then
      Refill
    else
      FPipelinePC := R[15];
  Result := ColdCycles + FBusCount + FInternalCycles;
end;

function TARMProcessor.StepThumb(Op: Word): Integer;
begin
  Result := 1;
  var PC := R[15];
  var Next := ARMAdd(PC, 2);
  var RD := Integer(Op and 7);
  var RS := Integer((Op shr 3) and 7);
  var Carry := (PSR shr 29) and 1;
  if Op and $F800 = $1800 then
  begin
    var V := R[(Op shr 6) and 7];
    if Op and $400 <> 0 then
      V := (Op shr 6) and 7;
    if Op and $200 <> 0 then
      R[RD] := AddFlags(R[RS], not V, 1)
    else
      R[RD] := AddFlags(R[RS], V, 0);
  end
  else if Op and $E000 = 0 then
  begin
    R[RD] := ARMShift(R[RS], (Op shr 11) and 3, (Op shr 6) and 31, True, Carry);
    NZ(R[RD]);
    PSR := (PSR and $DFFFFFFF) or (Carry shl 29);
  end
  else if Op and $E000 = $2000 then
  begin
    RD := (Op shr 8) and 7;
    case (Op shr 11) and 3 of
      0:
        begin
          R[RD] := Op and 255;
          NZ(R[RD]);
        end;
      1:
        AddFlags(R[RD], not Cardinal(Op and 255), 1);
      2:
        R[RD] := AddFlags(R[RD], Op and 255, 0);
      3:
        R[RD] := AddFlags(R[RD], not Cardinal(Op and 255), 1);
    end;
  end
  else if Op and $FC00 = $4000 then
  begin
    var V := R[RD];
    var B := R[RS];
    var Kind := (Op shr 6) and 15;
    case Kind of
      0:
        V := V and B;
      1:
        V := V xor B;
      2, 3, 4:
        V := ARMShift(V, Kind - 2, B and 255, False, Carry);
      5:
        V := AddFlags(V, B, Carry);
      6:
        V := AddFlags(V, not B, Carry);
      7:
        V := ARMShift(V, 3, B and 255, False, Carry);
      8:
        V := V and B;
      9:
        V := AddFlags(0, not B, 1);
      10:
        V := AddFlags(V, not B, 1);
      11:
        V := AddFlags(V, B, 0);
      12:
        V := V or B;
      13:
        begin
          // Thumb encodes Rd as the multiplier (ARM Rs), including early-out
          // timing and the otherwise undocumented carry result.
          var MultiplyClocks: Integer;
          if FARMv5 then
            MultiplyClocks := ARMMultiplyCycles(V, True)
          else
            ARM7MultiplyCarry(B, V, 0, False, True, Carry, MultiplyClocks);
          V := Cardinal((UInt64(V) * B) and $FFFFFFFF);
          Inc(FInternalCycles, MultiplyClocks);
          Result := 1 + FInternalCycles;
        end;
      14:
        V := V and not B;
      15:
        V := not B;
    end;
    if not (Kind in [5, 6, 9, 10, 11]) then
      NZ(V);
    if Kind in [2, 3, 4, 7] then
      Inc(FInternalCycles);
    if (Kind in [2, 3, 4, 7]) or ((Kind = 13) and not FARMv5) then
      PSR := (PSR and $DFFFFFFF) or (Carry shl 29);
    if not (Kind in [8, 10, 11]) then
      R[RD] := V;
  end
  else if Op and $FC00 = $4400 then
  begin
    RD := (Op and 7) or ((Op shr 4) and 8);
    RS := (Op shr 3) and 15;
    case (Op shr 8) and 3 of
      0:
        begin
          var V := ARMAdd(Reg(RD), Reg(RS));
          if RD = 15 then
          begin
            Next := V and $FFFFFFFE;
            FReloadRequested := True;
          end
          else
            R[RD] := V;
        end;
      1:
        AddFlags(Reg(RD), not Reg(RS), 1);
      2:
        if RD = 15 then
        begin
          Next := Reg(RS) and $FFFFFFFE;
          FReloadRequested := True;
        end
        else
          R[RD] := Reg(RS);
      3:
        begin
          var Target := Reg(RS);
          if FARMv5 and (Op and $80 <> 0) then
            R[14] := ARMAdd(PC, 2) or 1;
          BranchExchange(Target);
          Exit(3);
        end;
    end;
  end
  else if Op and $F800 = $4800 then
  begin
    Inc(FInternalCycles);
    R[(Op shr 8) and 7] := DataRead(ARMAdd(ARMAdd(PC, 4) and $FFFFFFFC, (Op and 255) * 4), 4);
    Result := 3;
  end
  else if Op and $F000 = $5000 then
  begin
    var Address := ARMAdd(R[RS], R[(Op shr 6) and 7]);
    var Kind := (Op shr 9) and 7;
    if Kind >= 3 then
      Inc(FInternalCycles);
    case Kind of
      0:
        DataWrite(Address, R[RD], 4);
      1:
        DataWrite(Address, R[RD], 2);
      2:
        DataWrite(Address, R[RD], 1);
      3:
        begin
          var V := DataRead(Address, 1);
          if V and $80 <> 0 then
            V := V or $FFFFFF00;
          R[RD] := V;
        end;
      4:
        R[RD] := DataRead(Address, 4);
      5:
        R[RD] := DataRead(Address, 2);
      6:
        R[RD] := DataRead(Address, 1);
      7:
        begin
          var V: Cardinal;
          if Address and 1 <> 0 then
          begin
            V := DataRead(Address, 1);
            if V and $80 <> 0 then
              V := V or $FFFFFF00;
          end
          else
          begin
            V := DataRead(Address, 2);
            if V and $8000 <> 0 then
              V := V or $FFFF0000;
          end;
          R[RD] := V;
        end;
    end;
    Result := 3;
  end
  else if Op and $E000 = $6000 then
  begin
    var Size := 4;
    if Op and $1000 <> 0 then
      Size := 1;
    var Address := ARMAdd(R[RS], ((Op shr 6) and 31) * Cardinal(Size));
    if Op and $800 <> 0 then
      Inc(FInternalCycles);
    if Op and $800 <> 0 then
      R[RD] := DataRead(Address, Size)
    else
      DataWrite(Address, R[RD], Size);
    Result := 3;
  end
  else if Op and $F000 = $8000 then
  begin
    var Address := ARMAdd(R[RS], ((Op shr 6) and 31) * 2);
    if Op and $800 <> 0 then
      Inc(FInternalCycles);
    if Op and $800 <> 0 then
      R[RD] := DataRead(Address, 2)
    else
      DataWrite(Address, R[RD], 2);
    Result := 3;
  end
  else if Op and $F000 = $9000 then
  begin
    RD := (Op shr 8) and 7;
    var Address := ARMAdd(R[13], (Op and 255) * 4);
    if Op and $800 <> 0 then
      Inc(FInternalCycles);
    if Op and $800 <> 0 then
      R[RD] := DataRead(Address, 4)
    else
      DataWrite(Address, R[RD], 4);
    Result := 3;
  end
  else if Op and $F000 = $A000 then
  begin
    var Base := ARMAdd(PC, 4) and $FFFFFFFC;
    if Op and $800 <> 0 then
      Base := R[13];
    R[(Op shr 8) and 7] := ARMAdd(Base, (Op and 255) * 4);
  end
  else if Op and $FF00 = $B000 then
  begin
    if Op and $80 = 0 then
      R[13] := ARMAdd(R[13], (Op and 127) * 4)
    else
      R[13] := ARMSub(R[13], (Op and 127) * 4);
  end
  else if Op and $F600 = $B400 then
  begin
    var List := Cardinal(Op and 255);
    if Op and $100 <> 0 then
      if Op and $800 <> 0 then
        List := List or $8000
      else
        List := List or $4000;
    var Count := 0;
    for var i := 0 to 15 do
      if List and (1 shl i) <> 0 then
        Inc(Count);
    var Address := R[13];
    var EmptyPop := (List = 0) and (Op and $800 <> 0);
    if EmptyPop then
      List := $8000;
    if Op and $800 = 0 then
    begin
      Address := ARMSub(Address, Count * 4);
      R[13] := Address;
    end;
    for var i := 0 to 15 do
      if List and (1 shl i) <> 0 then
      begin
        if Op and $800 <> 0 then
        begin
          var V := DataRead(Address, 4, False);
          if i = 15 then
          begin
            Next := V and $FFFFFFFE;
            if FARMv5 then
            begin
              PSR := (PSR and not Cardinal($20)) or ((V and 1) shl 5);
              if V and 1 = 0 then
                Next := V and $FFFFFFFC;
            end;
          end
          else
            R[i] := V;
        end
        else
          DataWrite(Address, R[i], 4);
        FDataSequential := True;
        Address := ARMAdd(Address, 4);
      end;
    if Op and $800 <> 0 then
      Inc(FInternalCycles);
    if List and $8000 <> 0 then
      FReloadRequested := True;
    if Op and $800 <> 0 then
      if EmptyPop then
        R[13] := ARMAdd(Address, 60)
      else
        R[13] := Address;
    Result := Count + 2;
  end
  else if Op and $F000 = $C000 then
  begin
    RS := (Op shr 8) and 7;
    var Address := R[RS];
    var List := Op and 255;
    if Op and $800 <> 0 then
      Inc(FInternalCycles);
    if List = 0 then
    begin
      if Op and $800 <> 0 then
        FReloadRequested := True;
      if Op and $800 <> 0 then
        Next := DataRead(Address, 4, False) and $FFFFFFFE
      else
        DataWrite(Address, ARMAdd(PC, 6), 4);
      R[RS] := ARMAdd(Address, 64);
    end
    else
    begin
      var Count := 0;
      for var i := 0 to 7 do
        if List and (1 shl i) <> 0 then
          Inc(Count);
      var FinalAddress := ARMAdd(Address, Count * 4);
      var First := True;
      for var i := 0 to 7 do
        if List and (1 shl i) <> 0 then
        begin
          if Op and $800 <> 0 then
            R[i] := DataRead(Address, 4, False)
          else if (i = RS) and not First then
            DataWrite(Address, FinalAddress, 4)
          else
            DataWrite(Address, R[i], 4);
          FDataSequential := True;
          First := False;
          Address := ARMAdd(Address, 4);
        end;
      if not ((Op and $800 <> 0) and (List and (1 shl RS) <> 0)) then
        R[RS] := Address;
      Result := Count + 2;
    end;
  end
  else if Op and $F000 = $D000 then
  begin
    var Cond := (Op shr 8) and 15;
    if Cond = 15 then
    begin
      R[15] := Next;
      if Assigned(FSWI) then
        FSWI(Byte(Op and 255))
      else
      begin
        ExceptionEntry($13, 8);
        R[14] := Next;
      end;
      Exit(3);
    end
    else if Cond = 14 then
    begin
      ExceptionEntry($1B, 4);
      R[14] := Next;
      Exit(3);
    end
    else if Condition(Cond) then
    begin
      FReloadRequested := True;
      var Offset := Integer(Op and 255);
      if Offset >= 128 then
        Dec(Offset, 256);
      Next := Cardinal((Int64(PC) + 4 + Offset * 2 + $100000000) and $FFFFFFFF);
      Result := 3;
    end;
  end
  else if Op and $F800 = $E000 then
  begin
    FReloadRequested := True;
    var Offset := Integer(Op and $7FF);
    if Offset >= $400 then
      Dec(Offset, $800);
    Next := Cardinal((Int64(PC) + 4 + Offset * 2 + $100000000) and $FFFFFFFF);
    Result := 3;
  end
  else if Op and $F800 = $F000 then
  begin
    var Offset := Integer(Op and $7FF);
    if Offset >= $400 then
      Dec(Offset, $800);
    R[14] := Cardinal((Int64(PC) + 4 + Int64(Offset) * 4096 + $100000000) and $FFFFFFFF);
  end
  else if FARMv5 and (Op and $F800 = $E800) then
  begin
    Next := ARMAdd(R[14], (Op and $7FF) * 2) and $FFFFFFFC;
    R[14] := ARMAdd(PC, 2) or 1;
    PSR := PSR and not Cardinal($20);
    FReloadRequested := True;
    Result := 3;
  end
  else if Op and $F800 = $F800 then
  begin
    FReloadRequested := True;
    Next := ARMAdd(R[14], (Op and $7FF) * 2) and $FFFFFFFE;
    R[14] := ARMAdd(PC, 2) or 1;
    Result := 3;
  end
  else
  begin
    ExceptionEntry($1B, 4);
    R[14] := Next;
    Exit(3);
  end;

  R[15] := Next;
end;

procedure TARMProcessor.Capture(out State: TARMCheckpoint);
begin
  State.Reserved := 0;
  Move(R, State.Registers, SizeOf(R));
  State.Status := PSR;
  State.SavedStatus := SPSR;
  Move(FBanked, State.Banked, SizeOf(FBanked));
  Move(FSaved, State.Saved, SizeOf(FSaved));
  State.Pipeline[0] := FPipeline[0];
  State.Pipeline[1] := FPipeline[1];
  State.Pipeline[2] := FPipeline[2];
  State.PipelinePC := FPipelinePC;
  State.PipelineThumb := FPipelineThumb;
  State.PipelineValid := FPipelineValid;
  State.FetchSequential := FFetchSequential;
  State.LDMGlitch := FLDMGlitch;
end;

procedure TARMProcessor.CaptureCached(var State: TARMCheckpoint; var Generation: UInt64);
begin
  State.Reserved := 0;

  // Fixed-size copies let the ARM compiler emit register-pair loads/stores
  // instead of calling the general RTL Move for every CPU instruction.
  State.Registers[0] := R[0];
  State.Registers[1] := R[1];
  State.Registers[2] := R[2];
  State.Registers[3] := R[3];
  State.Registers[4] := R[4];
  State.Registers[5] := R[5];
  State.Registers[6] := R[6];
  State.Registers[7] := R[7];
  State.Registers[8] := R[8];
  State.Registers[9] := R[9];
  State.Registers[10] := R[10];
  State.Registers[11] := R[11];
  State.Registers[12] := R[12];
  State.Registers[13] := R[13];
  State.Registers[14] := R[14];
  State.Registers[15] := R[15];
  State.Status := PSR;
  State.SavedStatus := SPSR;

  // The caller retains this checkpoint between instructions. Banked registers
  // change only on mode switches, reset, restore or snapshot load.
  if Generation <> FBankGeneration then
  begin
    Move(FBanked, State.Banked, SizeOf(FBanked));
    Move(FSaved, State.Saved, SizeOf(FSaved));
    Generation := FBankGeneration;
  end;
  State.Pipeline[0] := FPipeline[0];
  State.Pipeline[1] := FPipeline[1];
  State.Pipeline[2] := FPipeline[2];
  State.PipelinePC := FPipelinePC;
  State.PipelineThumb := FPipelineThumb;
  State.PipelineValid := FPipelineValid;
  State.FetchSequential := FFetchSequential;
  State.LDMGlitch := FLDMGlitch;
end;

procedure TARMProcessor.Restore(const State: TARMCheckpoint);
begin
  InvalidateMemoryPages;
  Inc(FBankGeneration);
  Move(State.Registers, R, SizeOf(R));
  PSR := State.Status;
  SPSR := State.SavedStatus;
  Move(State.Banked, FBanked, SizeOf(FBanked));
  Move(State.Saved, FSaved, SizeOf(FSaved));
  Move(State.Pipeline, FPipeline, SizeOf(FPipeline));
  FPipelinePC := State.PipelinePC;
  FPipelineThumb := State.PipelineThumb;
  FPipelineValid := State.PipelineValid;
  FFetchSequential := State.FetchSequential;
  FLDMGlitch := State.LDMGlitch;
end;

procedure TARMProcessor.SerializeState(State: TStateArchive);
begin
  if State.Loading then
    InvalidateMemoryPages;
  if State.Loading then
    Inc(FBankGeneration);
  State.Field(R, SizeOf(R));
  State.Field(PSR, SizeOf(PSR));
  State.Field(SPSR, SizeOf(SPSR));
  State.Field(FBanked, SizeOf(FBanked));
  State.Field(FSaved, SizeOf(FSaved));
  State.Field(FPipeline, SizeOf(FPipeline));
  State.Field(FPipelinePC, SizeOf(FPipelinePC));
  State.Field(FPipelineThumb, SizeOf(FPipelineThumb));
  State.Field(FPipelineValid, SizeOf(FPipelineValid));
  State.Field(FFetchSequential, SizeOf(FFetchSequential));
  State.Field(FLDMGlitch, SizeOf(FLDMGlitch));

  if State.Loading and ((FLDMGlitch < 0) or (FLDMGlitch > 2)) then
    raise EReadError.Create('Invalid ARM LDM state');

  if State.Loading and not ((PSR and 31) in [$10, $11, $12, $13, $17, $1B, $1F]) then
    raise EReadError.Create('Invalid ARM CPU mode');
end;

end.

