unit GBA.CPU;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, GBA.Multiply,
  HW.ARM.Shifter;

type
  TARMRead = function(Address: Cardinal; Size: Integer): Cardinal of object;

  TARMWrite = procedure(Address, Value: Cardinal; Size: Integer) of object;

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

  TGBAProcessor = class
  private
    FRead: TARMRead;
    FReadUnrotated: TARMRead;
    FSWI: TSoftwareInterrupt;
    FWrite: TARMWrite;
    FBusState: TARMBusState;
    FIdle: TARMIdle;
    FIRQSample: TARMIRQSample;
    FBusLock: TARMBusLock;
    FPipeline: array[0..2] of Cardinal;
    FPipelinePC, FPipelineThumb: Cardinal;
    FPipelineValid, FFetchSequential, FDataSequential: Boolean;
    FBusCount, FInternalCycles: Integer;
    FReloadRequested, FGlitchOnComplete: Boolean;
    FLDMGlitch: Integer;
    FBankGeneration: UInt64;
    FBanked: array[0..5, 0..6] of Cardinal;
    FSaved: array[0..5] of Cardinal;
    function DataRead(Address: Cardinal; Size: Integer; RotateValue: Boolean = True): Cardinal;
    procedure DataWrite(Address, Value: Cardinal; Size: Integer);
    function Fetch(Address: Cardinal; Size: Integer; Sequential: Boolean): Cardinal;
    procedure Refill;
    function Reg(Index: Integer): Cardinal; inline;
    function StepARM(Op: Cardinal): Integer;
    function StepThumb(Op: Word): Integer;
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
    property MemoryReadUnrotated: TARMRead read FReadUnrotated write FReadUnrotated;
    property MemoryWrite: TARMWrite read FWrite write FWrite;
  end;

function ARMAdd(A, B: Cardinal): Cardinal; inline;

function ARMSub(A, B: Cardinal): Cardinal; inline;

implementation

function ARMAdd(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(A) + B) and $FFFFFFFF);
end;

function ARMSub(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(A) + UInt64($100000000) - B) and $FFFFFFFF);
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

constructor TGBAProcessor.Create(Read: TARMRead; Write: TARMWrite);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  Reset;
end;

procedure TGBAProcessor.Reset;
begin
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

function TGBAProcessor.Reg(Index: Integer): Cardinal;
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

function TGBAProcessor.SavedStatus: Cardinal;
begin
  if Bank(PSR) = 0 then
    Result := PSR
  else
    Result := SPSR;
end;

procedure TGBAProcessor.SetPSR(Value: Cardinal);
begin
  Value := (Value and $F00000FF) or $10;
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

procedure TGBAProcessor.NZ(Value: Cardinal);
begin
  PSR := (PSR and $3FFFFFFF) or (Value and $80000000);
  if Value = 0 then
    PSR := PSR or $40000000;
end;

function TGBAProcessor.Condition(Code: Integer): Boolean;
begin
  var N := PSR and $80000000 <> 0;
  var Z := PSR and $40000000 <> 0;
  var C := PSR and $20000000 <> 0;
  var V := PSR and $10000000 <> 0;
  case Code shr 1 of
    0:
      Result := Z;
    1:
      Result := C;
    2:
      Result := N;
    3:
      Result := V;
    4:
      Result := C and not Z;
    5:
      Result := N = V;
    6:
      Result := (N = V) and not Z;
  else
    Result := True;
  end;
  if Code and 1 <> 0 then
    Result := not Result;
end;

function TGBAProcessor.Operand(Op: Cardinal; var Carry: Cardinal): Cardinal;
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

procedure TGBAProcessor.ExceptionEntry(Mode: Integer; Vector: Cardinal);
begin
  FReloadRequested := True;
  var Old := PSR;
  var ReturnAddress := ARMAdd(R[15], 4);
  SetPSR((PSR and $FFFFFFC0) or Cardinal(Mode) or $80);
  SPSR := Old;
  R[14] := ReturnAddress;
  R[15] := Vector;
  if Mode = $11 then
    PSR := PSR or $40;
end;

function TGBAProcessor.StepARM(Op: Cardinal): Integer;
begin
  Result := 1;
  var PC := R[15];
  if (Op shr 28 <> 14) and not Condition(Op shr 28) then
  begin
    R[15] := ARMAdd(PC, 4);
    Exit;
  end;

  var Next := ARMAdd(PC, 4);
  var RD := Integer((Op shr 12) and 15);
  var RN := Integer((Op shr 16) and 15);
  var Load := Op and $00100000 <> 0;
  var Carry: Cardinal := (PSR shr 29) and 1;
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
      FGlitchOnComplete := True;
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
      Mask := Mask or $F0000000;
    if Op and $00400000 <> 0 then
    begin
      if Bank(PSR) <> 0 then
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
    ARM7MultiplyCarry(MultiplyM, MultiplyS, Acc, False, True, MultiplyCarry, MultiplyClocks);
    var V := UInt64(MultiplyM) * MultiplyS;
    if Op and $00200000 <> 0 then
      V := V + Reg(RD);
    R[Dest] := Cardinal(V and $FFFFFFFF);
    if Load then
    begin
      NZ(R[Dest]);
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
      PSR := (PSR and $1FFFFFFF) or (R[RN] and $80000000) or (MultiplyCarry shl 29);
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

procedure TGBAProcessor.SetStatus(Value: Cardinal);
begin
  SetPSR(Value);
end;

procedure TGBAProcessor.BranchExchange(Value: Cardinal);
begin
  FReloadRequested := True;
  PSR := (PSR and not $20) or ((Value and 1) shl 5);
  if PSR and $20 <> 0 then
    R[15] := Value and $FFFFFFFE
  else
    R[15] := Value and $FFFFFFFC;
end;

function TGBAProcessor.AddFlags(A, B, Carry: Cardinal): Cardinal;
begin
  var Sum := UInt64(A) + B + Carry;
  Result := Cardinal(Sum and $FFFFFFFF);
  NZ(Result);
  var Overflow := (not (A xor B)) and (A xor Result) and $80000000 <> 0;
  PSR := (PSR and $CFFFFFFF) or (Cardinal(Ord(Sum > $FFFFFFFF)) shl 29) or
    (Cardinal(Ord(Overflow)) shl 28);
end;

function TGBAProcessor.Fetch(Address: Cardinal; Size: Integer; Sequential: Boolean): Cardinal;
begin
  if FLDMGlitch > 0 then
    Dec(FLDMGlitch);
  if Assigned(FBusState) then
    FBusState(Sequential, True);
  Result := FRead(Address, Size);
  Inc(FBusCount);
end;

function TGBAProcessor.DataRead(Address: Cardinal; Size: Integer; RotateValue: Boolean): Cardinal;
begin
  if FLDMGlitch > 0 then
    Dec(FLDMGlitch);
  if Assigned(FBusState) then
    FBusState(FDataSequential, False);
  FFetchSequential := False;
  if RotateValue then
    Result := FRead(Address, Size)
  else if Assigned(FReadUnrotated) then
    Result := FReadUnrotated(Address, Size)
  else
    Result := FRead(Address and not Cardinal(Size - 1), Size);
  Inc(FBusCount);
end;

procedure TGBAProcessor.DataWrite(Address, Value: Cardinal; Size: Integer);
begin
  if FLDMGlitch > 0 then
    Dec(FLDMGlitch);
  if Assigned(FBusState) then
    FBusState(FDataSequential, False);
  FFetchSequential := False;
  FWrite(Address, Value, Size);
  Inc(FBusCount);
end;

procedure TGBAProcessor.Refill;
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

function TGBAProcessor.Step(IRQ: Boolean): Integer;
begin
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

function TGBAProcessor.StepThumb(Op: Word): Integer;
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
    if Kind in [2, 3, 4, 7, 13] then
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
          BranchExchange(Reg(RS));
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
            Next := V and $FFFFFFFE
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

procedure TGBAProcessor.Capture(out State: TARMCheckpoint);
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

procedure TGBAProcessor.CaptureCached(var State: TARMCheckpoint; var Generation: UInt64);
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

procedure TGBAProcessor.Restore(const State: TARMCheckpoint);
begin
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

procedure TGBAProcessor.SerializeState(State: TStateArchive);
begin
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
    raise EReadError.Create('Invalid GBA LDM state');

  if State.Loading and not ((PSR and 31) in [$10, $11, $12, $13, $17, $1B, $1F]) then
    raise EReadError.Create('Invalid GBA CPU mode');
end;

end.

