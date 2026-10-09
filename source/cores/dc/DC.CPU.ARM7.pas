unit DC.CPU.ARM7;

// ARM7DI (ARMv3) interpreter. Bus accesses use integer addresses, never pointers.

interface

uses
  System.SysUtils;

type
  TARMRead = function(Address: Cardinal; Size: Integer): Cardinal of object;

  TARMWrite = procedure(Address, Value: Cardinal; Size: Integer) of object;

  TARM7 = class
  private
    FRead: TARMRead;
    FWrite: TARMWrite;
    FBanked: array[0..5, 0..6] of Cardinal;
    FSaved: array[0..5] of Cardinal;
    function Reg(Index: Integer): Cardinal;
    function Condition(Code: Integer): Boolean;
    procedure SetPSR(Value: Cardinal);
    procedure NZ(Value: Cardinal);
    function Shift(Value: Cardinal; Kind, Count: Integer; Immediate: Boolean; var Carry: Cardinal): Cardinal;
    function Operand(Op: Cardinal; var Carry: Cardinal): Cardinal;
    procedure ExceptionEntry(Mode: Integer; Vector: Cardinal);
  public
    R: array[0..15] of Cardinal;
    PSR, SPSR: Cardinal;
    constructor Create(Read: TARMRead; Write: TARMWrite);
    procedure Reset;
    function Step(FIQ: Boolean): Integer;
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

function Rotate(V: Cardinal; Count: Integer): Cardinal; inline;
begin
  Count := Count and 31;
  if Count = 0 then
    Result := V
  else
    Result := (V shr Count) or (V shl (32 - Count));
end;

function Bank(Mode: Integer): Integer; inline;
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

constructor TARM7.Create(Read: TARMRead; Write: TARMWrite);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  Reset;
end;

procedure TARM7.Reset;
begin
  FillChar(R, SizeOf(R), 0);
  FillChar(FBanked, SizeOf(FBanked), 0);
  FillChar(FSaved, SizeOf(FSaved), 0);
  PSR := $D3;
  SPSR := 0;
end;

function TARM7.Reg(Index: Integer): Cardinal;
begin
  Result := R[Index];
  if Index = 15 then
    Result := ARMAdd(Result, 8);
end;

procedure TARM7.SetPSR(Value: Cardinal);
begin
  var Old := Bank(PSR and 31);
  var New := Bank(Value and 31);
  if Old <> New then
  begin
    var Start := 13;
    if (Old = 1) or (New = 1) then
      Start := 8;
    for var I := Start to 14 do
    begin
      var OldBank := Old;
      var NewBank := New;
      if I < 13 then
      begin
        if Old <> 1 then
          OldBank := 0;
        if New <> 1 then
          NewBank := 0;
      end;
      FBanked[OldBank, I - 8] := R[I];
      R[I] := FBanked[NewBank, I - 8];
    end;
    FSaved[Old] := SPSR;
    SPSR := FSaved[New];
  end;
  PSR := Value;
end;

procedure TARM7.NZ(Value: Cardinal);
begin
  PSR := (PSR and $3FFFFFFF) or (Value and $80000000);
  if Value = 0 then
    PSR := PSR or $40000000;
end;

function TARM7.Condition(Code: Integer): Boolean;
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

function TARM7.Shift(Value: Cardinal; Kind, Count: Integer; Immediate: Boolean; var Carry: Cardinal): Cardinal;
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
          Result := Rotate(Value, Count);
          Carry := Result shr 31;
        end;
      end;
  end;
end;

function TARM7.Operand(Op: Cardinal; var Carry: Cardinal): Cardinal;
begin
  if Op and $02000000 <> 0 then
  begin
    var Count := Integer((Op shr 8) and 15) * 2;
    Result := Rotate(Op and 255, Count);
    if Count <> 0 then
      Carry := Result shr 31;
    Exit;
  end;
  var Value := Reg(Op and 15);
  var Count := Integer((Op shr 7) and 31);
  var Immediate := Op and $10 = 0;
  if not Immediate then
  begin
    Count := Reg((Op shr 8) and 15) and 255;
    if Op and 15 = 15 then
      Value := ARMAdd(Value, 4);
  end;
  Result := Shift(Value, (Op shr 5) and 3, Count, Immediate, Carry);
end;

procedure TARM7.ExceptionEntry(Mode: Integer; Vector: Cardinal);
begin
  var Old := PSR;
  var ReturnAddress := ARMAdd(R[15], 4);
  SetPSR((PSR and $FFFFFFC0) or Cardinal(Mode) or $80);
  SPSR := Old;
  R[14] := ReturnAddress;
  R[15] := Vector;
  if Mode = $11 then
    PSR := PSR or $40;
end;

function TARM7.Step(FIQ: Boolean): Integer;
begin
  Result := 2;
  if FIQ and (PSR and $40 = 0) then
  begin
    ExceptionEntry($11, $1C);
    Exit(4);
  end;

  var PC := R[15];
  var Op := FRead(PC, 4);
  if not Condition(Op shr 28) then
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
    ExceptionEntry($13, 8);
    Exit(4);
  end;

  if Op and $0FFFFFF0 = $012FFF10 then
  begin
    Next := Reg(Op and 15) and $FFFFFFFC;
    R[15] := Next;
    Exit(4);
  end;

  if Op and $0E000000 = $0A000000 then
  begin
    if Op and $01000000 <> 0 then
      R[14] := Next;
    var Offset := Int64(Op and $FFFFFF) * 4;
    if Op and $800000 <> 0 then
      Dec(Offset, $4000000);
    Next := Cardinal((Int64(PC) + 8 + Offset + $100000000) and $FFFFFFFF);
    Result := 4;
  end
  else if Op and $0E000000 = $08000000 then
  begin
    var List := Op and $FFFF;
    var Count := 0;
    for var I := 0 to 15 do
      if List and (1 shl I) <> 0 then
        Inc(Count);
    if Count = 0 then
      raise EArgumentException.Create('ARM empty register list');

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
    for var I := 0 to 15 do
      if List and (1 shl I) <> 0 then
      begin
        if Load then
        begin
          var V := FRead(Address, 4);
          if I = 15 then
            Next := V and $FFFFFFFC
          else
            R[I] := V;
        end
        else
        begin
          var V := Reg(I);
          if I = 15 then
            V := ARMAdd(V, 4);
          FWrite(Address, V, 4);
        end;
        Address := ARMAdd(Address, 4);
      end;
    if (Op and $00200000 <> 0) and not (Load and (List and (1 shl RN) <> 0)) then
      R[RN] := Writeback;
    if Load and (List and $8000 <> 0) and (Op and $00400000 <> 0) then
      SetPSR(SPSR);
    Result := 2 + Count;
  end
  else if Op and $0C000000 = $04000000 then
  begin
    var Offset := Op and $FFF;
    if Op and $02000000 <> 0 then
      Offset := Shift(Reg(Op and 15), (Op shr 5) and 3, (Op shr 7) and 31, True, Carry);
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
      var Value := FRead(Address, Size);
      if RD = 15 then
        Next := Value and $FFFFFFFC
      else
        R[RD] := Value;
    end
    else
    begin
      var Value := Reg(RD);
      if RD = 15 then
        Value := ARMAdd(Value, 4);
      FWrite(Address, Value, Size);
    end;
    if (Op and $00200000 <> 0) or (Op and $01000000 = 0) then
      R[RN] := Adjusted;
    Result := 3;
  end
  else if Op and $0FBF0FFF = $010F0000 then
  begin
    var V := PSR;
    if Op and $00400000 <> 0 then
      V := SPSR;
    R[RD] := V;
  end
  else if Op and $0DB0F000 = $0120F000 then
  begin
    var V := Operand(Op, Carry);
    var Mask: Cardinal := 0;
    for var I := 0 to 3 do
      if Op and (1 shl (16 + I)) <> 0 then
        Mask := Mask or ($FF shl (I * 8));
    if Op and $00400000 <> 0 then
      SPSR := (SPSR and not Mask) or (V and Mask)
    else
    begin
      if Bank(PSR and 31) = 0 then
        Mask := Mask and $FF000000;
      SetPSR((PSR and not Mask) or (V and Mask));
    end;
  end
  else if Op and $0FC000F0 = $00000090 then
  begin
    var RM := Integer(Op and 15);
    var RS := Integer((Op shr 8) and 15);
    var Dest := Integer((Op shr 16) and 15);
    var V := UInt64(Reg(RM)) * Reg(RS);
    if Op and $00200000 <> 0 then
      V := V + Reg(RD);
    R[Dest] := Cardinal(V and $FFFFFFFF);
    if Load then
      NZ(R[Dest]);
    Result := 4;
  end
  else if Op and $0F8000F0 = $00800090 then
  begin
    var RM := Reg(Op and 15);
    var RS := Reg((Op shr 8) and 15);
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
      PSR := (PSR and $3FFFFFFF) or (R[RN] and $80000000);
      if V = 0 then
        PSR := PSR or $40000000;
    end;
    Result := 5;
  end
  else if Op and $0FB00FF0 = $01000090 then
  begin
    var Size := 4;
    if Op and $00400000 <> 0 then
      Size := 1;
    var Address := Reg(RN);
    var Old := FRead(Address, Size);
    FWrite(Address, Reg(Op and 15), Size);
    R[RD] := Old;
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
      var Size := 2;
      if Kind = 2 then
        Size := 1;
      var V := FRead(Address, Size);
      if Kind = 2 then
      begin
        if V and $80 <> 0 then
          V := V or $FFFFFF00;
      end
      else if Kind = 3 then
        if V and $8000 <> 0 then
          V := V or $FFFF0000;
      R[RD] := V;
    end
    else
      FWrite(Address, Reg(RD), 2);
    if (Op and $00200000 <> 0) or (Op and $01000000 = 0) then
      R[RN] := Adjusted;
    Result := 3;
  end
  else if Op and $0C000000 = 0 then
  begin
    var Kind := (Op shr 21) and 15;
    var V1 := Reg(RN);
    var V2 := Operand(Op, Carry);
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
        Next := V and $FFFFFFFC;
        if SetFlags then
          SetPSR(SPSR);
        Result := 4;
      end
      else
        R[RD] := V;
  end
  else
    raise EArgumentException.CreateFmt('Unsupported ARM instruction %.8x at %.8x', [Op, PC]);

  R[15] := Next;
end;

end.

