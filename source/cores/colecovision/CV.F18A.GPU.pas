unit CV.F18A.GPU;

interface

uses
  Core.Snapshots;

type
  TCVGPURead = function(Address: Word): Byte of object;

  TCVGPUWrite = procedure(Address: Word; Value: Byte) of object;

  // F18A's 100 MHz TMS9900-derived GPU; HDL: dnotq/f18a/f18a_gpu.vhd.
  TCVF18AGPU = class
  private
    type
      TOperand = record
        Address, Value: Word;
        RegisterIndex: Byte;
        Direct: Boolean;
      end;
  private
    FR: array[0..15] of Word;
    FPC, FStatus, FOverride: Word;
    FRunning, FOverrideValid: Boolean;
    FCredit: Integer;
    FRead: TCVGPURead;
    FWrite: TCVGPUWrite;
    function ReadWord(Address: Integer): Word;
    procedure WriteWord(Address, Value: Integer);
    function Fetch: Word;
    function Operand(Spec: Integer; Bytes: Boolean): TOperand;
    procedure Store(const Op: TOperand; Value: Integer; Bytes: Boolean);
    procedure Flag(Mask: Word; Value: Boolean);
    procedure Logic(Value: Integer; Bytes: Boolean);
    procedure Compare(A, B: Integer; Bytes: Boolean);
    function Arithmetic(A, B: Integer; Subtract, Bytes: Boolean): Integer;
    procedure Pixel(XY: Word; Reg: Integer);
    function Execute: Integer;
  public
    constructor Create(ReadBus: TCVGPURead; WriteBus: TCVGPUWrite);
    procedure Reset;
    procedure Load(Address: Word; Run: Boolean);
    procedure Trigger;
    procedure Advance(Clocks: Integer);
    procedure Stall(Clocks: Integer);
    procedure SerializeState(State: TStateArchive);
    property Running: Boolean read FRunning;
    property PC: Word read FPC;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math;

const
  LGT = $8000;
  AGT = $4000;
  EQ = $2000;
  Carry = $1000;
  Overflow = $0800;
  Parity = $0400;

function SignedValue(Value: Integer; Bytes: Boolean): Integer;
begin
  Result := Value;
  if Bytes then
  begin
    Result := (Value shr 8) and $FF;
    if Result >= $80 then
      Dec(Result, $100);
  end
  else if Result >= $8000 then
    Dec(Result, $10000);
end;

constructor TCVF18AGPU.Create(ReadBus: TCVGPURead; WriteBus: TCVGPUWrite);
begin
  inherited Create;
  FRead := ReadBus;
  FWrite := WriteBus;
  Reset;
end;

procedure TCVF18AGPU.Reset;
begin
  FillChar(FR, SizeOf(FR), 0);
  FPC := $4000;
  FStatus := 0;
  FOverride := 0;
  FRunning := False;
  FOverrideValid := False;
  FCredit := 0;
end;

procedure TCVF18AGPU.Load(Address: Word; Run: Boolean);
begin
  FPC := Address and $FFFE;
  FRunning := Run;
  FOverrideValid := False;
  FCredit := 0;
end;

procedure TCVF18AGPU.Trigger;
begin
  FRunning := True;
end;

function TCVF18AGPU.ReadWord(Address: Integer): Word;
begin
  Address := Address and $FFFE;
  Result := (Integer(FRead(Address)) shl 8) or FRead(Address + 1);
end;

procedure TCVF18AGPU.WriteWord(Address, Value: Integer);
begin
  Address := Address and $FFFE;
  FWrite(Address, (Value shr 8) and $FF);
  FWrite(Address + 1, Value and $FF);
end;

function TCVF18AGPU.Fetch: Word;
begin
  Result := ReadWord(FPC);
  FPC := (Integer(FPC) + 2) and $FFFF;
end;

function TCVF18AGPU.Operand(Spec: Integer; Bytes: Boolean): TOperand;
begin
  Result := Default(TOperand);
  var Index := Spec and 15;
  Result.RegisterIndex := Index;
  Result.Direct := Spec and $30 = 0;
  if Result.Direct then
  begin
    Result.Value := FR[Index];
    Result.Address := Index * 2;
    Exit;
  end;
  var Address := Integer(FR[Index]);
  case Spec and $30 of
    $20:
      begin
        Address := Fetch;
        if Index <> 0 then
          Address := (Address + FR[Index]) and $FFFF;
      end;
    $30:
      FR[Index] := (Integer(FR[Index]) + 2 - Ord(Bytes)) and $FFFF;
  end;
  Result.Address := Address;
  if Bytes then
    Result.Value := Word(FRead(Address)) shl 8
  else
    Result.Value := ReadWord(Address);
end;

procedure TCVF18AGPU.Store(const Op: TOperand; Value: Integer; Bytes: Boolean);
begin
  if Op.Direct then
    if Bytes then
      FR[Op.RegisterIndex] := (Value and $FF00) or (FR[Op.RegisterIndex] and $FF)
    else
      FR[Op.RegisterIndex] := Value and $FFFF
  else if Bytes then
    FWrite(Op.Address, (Value shr 8) and $FF)
  else
    WriteWord(Op.Address, Value);
end;

procedure TCVF18AGPU.Flag(Mask: Word; Value: Boolean);
begin
  FStatus := FStatus and not Mask;
  if Value then
    FStatus := FStatus or Mask;
end;

procedure TCVF18AGPU.Logic(Value: Integer; Bytes: Boolean);
begin
  Value := Value and $FFFF;
  if Bytes then
    Value := Value and $FF00;
  Flag(LGT, Value <> 0);
  Flag(AGT, SignedValue(Value, Bytes) > 0);
  Flag(EQ, Value = 0);
  if Bytes then
  begin
    var V := Value shr 8;
    V := V xor (V shr 4);
    V := V xor (V shr 2);
    V := V xor (V shr 1);
    Flag(Parity, Odd(V));
  end;
end;

procedure TCVF18AGPU.Compare(A, B: Integer; Bytes: Boolean);
begin
  if Bytes then
  begin
    A := A and $FF00;
    B := B and $FF00;
    var Saved := FStatus;
    Logic(A, True);
    FStatus := (Saved and not Parity) or (FStatus and Parity);
  end;
  Flag(LGT, A > B);
  Flag(AGT, SignedValue(A, Bytes) > SignedValue(B, Bytes));
  Flag(EQ, A = B);
end;

function TCVF18AGPU.Arithmetic(A, B: Integer; Subtract, Bytes: Boolean): Integer;
begin
  var Limit := $FFFF;
  var Upper := 32767;
  var Lower := -32768;
  if Bytes then
  begin
    A := A and $FF00;
    B := B and $FF00;
    Limit := $FF;
    Upper := 127;
    Lower := -128;
  end;
  var SignedA := SignedValue(A, Bytes);
  var SignedB := SignedValue(B, Bytes);
  if Bytes then
  begin
    A := A shr 8;
    B := B shr 8;
  end;
  var V := A + B;
  var S := SignedA + SignedB;
  if Subtract then
  begin
    V := A - B;
    S := SignedA - SignedB;
  end;
  if Subtract then
    Flag(Carry, A >= B)
  else
    Flag(Carry, V > Limit);
  Flag(Overflow, (S > Upper) or (S < Lower));
  Result := V and Limit;
  if Bytes then
    Result := Result shl 8;
  Logic(Result, Bytes);
end;

procedure TCVF18AGPU.Pixel(XY: Word; Reg: Integer);
begin
  var Options := FR[Reg];
  var X := XY shr 8;
  var Y := XY and $FF;
  var Width := Integer(FRead($6023));
  if Width = 0 then
    Width := 256;
  var Address := ((Integer(FRead($6020)) shl 6) + Y * ((Width + 3) div 4) + X div 4) and $3FFF;
  if Options and $8000 <> 0 then
    Address := ((Integer(FRead($6004) and 4) shl 11) +
      (Y div 8) * 256 + (X and $F8) + (Y and 7)) and $3FFF;
  if Options and $C000 <> 0 then
  begin
    FR[Reg] := Address;
    Exit;
  end;
  var Data := FRead(Address);
  var Shift := 6 - (X and 3) * 2;
  var Old := (Data shr Shift) and 3;
  if Options and $800 <> 0 then
    FR[Reg] := (Options and $FFFC) or Old;
  var WritePixel := Options and $400 = 0;
  if Options and $200 <> 0 then
    WritePixel := WritePixel and ((Old = ((Options shr 4) and 3)) = (Options and $100 <> 0));
  if WritePixel then
    FWrite(Address, (Data and not (3 shl Shift)) or ((Options and 3) shl Shift));
end;

function TCVF18AGPU.Execute: Integer;
var
  Source, Dest: TOperand;
begin
  Result := 6;
  var Op: Word;
  if FOverrideValid then
  begin
    Op := FOverride;
    FOverrideValid := False;
  end
  else
    Op := Fetch;
  var Bytes := Op and $1000 <> 0;
  if Op >= $4000 then
  begin
    Source := Operand(Op and $3F, Bytes);
    Dest := Operand((Op shr 6) and $3F, Bytes);
    var A := Integer(Source.Value);
    var B := Integer(Dest.Value);
    if Bytes then
    begin
      A := A and $FF00;
      B := B and $FF00;
    end;
    var Value := 0;
    case Op shr 12 of
      4, 5:
        Value := B and not A;
      6, 7:
        Value := Arithmetic(B, A, True, Bytes);
      8, 9:
        begin
          // C source,destination compares the source against destination.
          Compare(A, B, Bytes);
          Exit(10);
        end;
      10, 11:
        Value := Arithmetic(B, A, False, Bytes);
      12, 13:
        Value := A;
      14, 15:
        Value := B or A;
    end;
    Value := Value and $FFFF;
    Logic(Value, Bytes);
    Store(Dest, Value, Bytes);
    Exit(10);
  end;
  var Reg := (Op shr 6) and 15;
  if Op >= $2000 then
  begin
    Source := Operand(Op and $3F, Op and $F800 = $3000);
    case (Op shr 10) and 7 of
      0:
        Flag(EQ, (Source.Value and not FR[Reg]) = 0);
      1:
        Flag(EQ, (Source.Value and FR[Reg]) = 0);
      2:
        begin
          FR[Reg] := FR[Reg] xor Source.Value;
          Logic(FR[Reg], False);
        end;
      3:
        Pixel(Source.Value, Reg);
      4:
        begin
          Logic($FF00, True);
        end; // SPI output, no attached flash device.
        5:
        begin
          Store(Source, $FF00, True);
          Logic($FF00, True);
        end;
      6:
        begin
          var Product := Cardinal(FR[Reg]) * Cardinal(Source.Value);
          FR[Reg] := Product shr 16;
          FR[(Reg + 1) and 15] := Product and $FFFF;
        end;
      7:
        if (Source.Value = 0) or (FR[Reg] >= Source.Value) then
          Flag(Overflow, True)
        else
        begin
          var Dividend := (Cardinal(FR[Reg]) shl 16) or FR[(Reg + 1) and 15];
          FR[Reg] := Dividend div Source.Value;
          FR[(Reg + 1) and 15] := Dividend mod Source.Value;
          Flag(Overflow, False);
        end;
    end;
    Exit(12);
  end;
  if Op >= $1000 then
  begin
    var Jump := False;
    case (Op shr 8) and 15 of
      0:
        Jump := True;
      1:
        Jump := FStatus and (AGT or EQ) = 0;
      2:
        Jump := (FStatus and LGT = 0) or (FStatus and EQ <> 0);
      3:
        Jump := FStatus and EQ <> 0;
      4:
        Jump := FStatus and (LGT or EQ) <> 0;
      5:
        Jump := FStatus and AGT <> 0;
      6:
        Jump := FStatus and EQ = 0;
      7:
        Jump := FStatus and Carry = 0;
      8:
        Jump := FStatus and Carry <> 0;
      9:
        Jump := FStatus and Overflow = 0;
      10:
        Jump := FStatus and (LGT or EQ) = 0;
      11:
        Jump := (FStatus and LGT <> 0) and (FStatus and EQ = 0);
      12:
        Jump := FStatus and Parity <> 0;
    end;
    var Offset := Integer(Op and $FF);
    if Offset >= 128 then
      Dec(Offset, 256);
    if Jump then
      FPC := (Integer(FPC) + Offset * 2) and $FFFF;
    Exit;
  end;
  if Op >= $0800 then
  begin
    var Kind := (Op shr 8) and 7;
    Reg := Op and 15;
    if Kind in [0, 1, 2, 3, 6] then
    begin
      var Count := (Op shr 4) and 15;
      if Count = 0 then
        Count := FR[0] and 15;
      if Count = 0 then
        Count := 16;
      var Value := Integer(FR[Reg]);
      var Changed := False;
      for var I := 1 to Count do
      begin
        var Before := Value;
        var C := Value and 1 <> 0;
        if Kind in [2, 6] then
          C := Value and $8000 <> 0;
        case Kind of
          0:
            Value := (Value shr 1) or (Value and $8000);
          1:
            Value := Value shr 1;
          2:
            Value := (Value shl 1) and $FFFF;
          3:
            Value := (Value shr 1) or (Ord(C) shl 15);
          6:
            Value := ((Value shl 1) or Ord(C)) and $FFFF;
        end;
        Changed := Changed or ((Before xor Value) and $8000 <> 0);
        Flag(Carry, C);
      end;
      FR[Reg] := Value;
      Logic(Value, False);
      if Kind = 2 then
        Flag(Overflow, Changed);
      Exit(Count + 6);
    end;
    case Kind of
      4:
        if Op and $80 = 0 then
        begin
          FR[15] := (Integer(FR[15]) + 2) and $FFFF;
          FPC := ReadWord(FR[15]) and $FFFE;
        end
        else
        begin
          Source := Operand(Op and $3F, False);
          WriteWord(FR[15], FPC);
          FR[15] := (Integer(FR[15]) - 2) and $FFFF;
          FPC := Source.Address and $FFFE;
        end;
      5:
        begin
          Source := Operand(Op and $3F, False);
          WriteWord(FR[15], Source.Value);
          FR[15] := (Integer(FR[15]) - 2) and $FFFF;
        end;
      7:
        begin
          FR[15] := (Integer(FR[15]) + 2) and $FFFF;
          var Value := ReadWord(FR[15]);
          Dest := Operand(Op and $3F, False);
          Store(Dest, Value, False);
        end;
    end;
    Exit(10);
  end;
  if Op >= $0400 then
  begin
    var Kind := (Op shr 6) and 15;
    if (Kind = 0) or (Kind >= 14) then
      Exit;
    Source := Operand(Op and $3F, False);
    var Value := Integer(Source.Value);
    case Kind of
      1:
        begin
          FPC := Source.Address and $FFFE;
          Exit;
        end;
      2:
        begin
          FOverride := Source.Value;
          FOverrideValid := True;
          Exit;
        end;
      3:
        Value := 0;
      4:
        Value := Arithmetic(0, Value, True, False);
      5:
        begin
          Value := Value xor $FFFF;
          Logic(Value, False);
        end;
      6:
        Value := Arithmetic(Value, 1, False, False);
      7:
        Value := Arithmetic(Value, 2, False, False);
      8:
        Value := Arithmetic(Value, 1, True, False);
      9:
        Value := Arithmetic(Value, 2, True, False);
      10:
        begin
          FR[11] := FPC;
          FPC := Source.Address and $FFFE;
          Exit;
        end;
      11:
        Value := ((Value shl 8) or (Value shr 8)) and $FFFF;
      12:
        Value := $FFFF;
      13:
        begin
          Logic(Value, False);
          Flag(Carry, Value = 0);
          Flag(Overflow, Value = $8000);
          if Value and $8000 <> 0 then
            Value := (-Value) and $FFFF;
        end;
    end;
    Store(Source, Value, False);
    Exit(10);
  end;
  Reg := Op and 15;
  case Op and $FFE0 of
    $0200:
      begin
        FR[Reg] := Fetch;
        Logic(FR[Reg], False);
      end;
    $0220:
      FR[Reg] := Arithmetic(FR[Reg], Fetch, False, False);
    $0240:
      begin
        FR[Reg] := FR[Reg] and Fetch;
        Logic(FR[Reg], False);
      end;
    $0260:
      begin
        FR[Reg] := FR[Reg] or Fetch;
        Logic(FR[Reg], False);
      end;
    $0280:
      Compare(FR[Reg], Fetch, False);
    $02C0:
      FR[Reg] := FStatus;
    $0340:
      FRunning := False;
    $0380:
      begin
        FPC := FR[14] and $FFFE;
        FStatus := FR[15] and $FC00;
      end;
    // CKON/CKOF select the external SPI flash; without one both read FF.
  end;
end;

procedure TCVF18AGPU.Stall(Clocks: Integer);
begin
  Dec(FCredit, Clocks);
end;

procedure TCVF18AGPU.Advance(Clocks: Integer);
begin
  if not FRunning then
  begin
    FCredit := 0;
    Exit;
  end;
  Inc(FCredit, Clocks);
  while (FCredit > 0) and FRunning do
    Dec(FCredit, Execute);
end;

procedure TCVF18AGPU.SerializeState(State: TStateArchive);
begin
  State.Field(FR, SizeOf(FR));
  State.Field(FPC, SizeOf(FPC));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FOverride, SizeOf(FOverride));
  State.Field(FRunning, SizeOf(FRunning));
  State.Field(FOverrideValid, SizeOf(FOverrideValid));
  State.Field(FCredit, SizeOf(FCredit));
  if State.Loading and ((FPC and 1 <> 0) or (FStatus and $3FF <> 0) or
    (FCredit < -200000) or (FCredit > 1000)) then
    raise EReadError.Create('Invalid F18A GPU state');
end;

end.

