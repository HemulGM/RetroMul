unit DC.Sound.AICA.DSP;

interface

type
  TDSPRead = function(Address: Cardinal): Byte of object;

  TDSPWrite = procedure(Address: Cardinal; Value: Byte) of object;

  TAICADSP = class
  private
    FRead: TDSPRead;
    FWrite: TDSPWrite;
    FRegisters: array[0..4095] of Byte;
    FTemp: array[0..127] of Integer;
    FMemory: array[0..31] of Integer;
    FMix: array[0..15] of Integer;
    FEffects: array[0..15] of SmallInt;
    FDelay: Integer;
    function WordAt(Index: Integer): Integer;
  public
    RingBase, RingLength: Integer;
    constructor Create(Read: TDSPRead; Write: TDSPWrite);
    procedure Reset;
    procedure WriteRegister(Address: Integer; Value: Byte);
    function ReadRegister(Address: Integer): Byte;
    procedure Mix(Channel, Sample: Integer);
    procedure Step;
    function Effect(Channel: Integer): Integer;
  end;

implementation

uses
  System.Math;

function Sar(Value: Int64; Count: Integer): Integer;
begin
  if Value >= 0 then
    Result := Value shr Count
  else
    Result := -((-Value + (Int64(1) shl Count) - 1) shr Count);
end;

function SignedBits(Value: Int64; Bits: Integer): Integer;
begin
  Result := Value and ((Int64(1) shl Bits) - 1);
  if Result and (1 shl (Bits - 1)) <> 0 then
    Dec(Result, 1 shl Bits);
end;

function Pack(Value: Integer): Word;
begin
  var Sign := (Value shr 23) and 1;
  var V := Value and $FFFFFF;
  var Test := (V xor (V shl 1)) and $FFFFFF;
  var Exponent := 0;
  while (Exponent < 12) and (Test and $800000 = 0) do
  begin
    Test := Test shl 1;
    Inc(Exponent);
  end;
  var Mantissa: Integer;
  if Exponent < 12 then
    Mantissa := Integer((UInt64(V) shl Exponent) and $3FFFFF) shr 11
  else
    Mantissa := V;
  Result := (Mantissa and $7FF) or (Exponent shl 11) or (Sign shl 15);
end;

function Unpack(Value: Word): Integer;
begin
  var Sign := (Value shr 15) and 1;
  var Exponent := (Value shr 11) and 15;
  var V := Integer(Value and $7FF) shl 11;
  if Exponent > 11 then
  begin
    Exponent := 11;
    V := V or (Sign shl 22);
  end
  else
    V := V or ((Sign xor 1) shl 22);
  V := V or (Sign shl 23);
  Result := Sar(SignedBits(V, 24), Exponent);
end;

constructor TAICADSP.Create(Read: TDSPRead; Write: TDSPWrite);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  Reset;
end;

procedure TAICADSP.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FTemp, SizeOf(FTemp), 0);
  FillChar(FMemory, SizeOf(FMemory), 0);
  FillChar(FMix, SizeOf(FMix), 0);
  FillChar(FEffects, SizeOf(FEffects), 0);
  FDelay := 0;
  RingBase := 0;
  RingLength := 8192;
end;

function TAICADSP.WordAt(Index: Integer): Integer;
begin
  Index := Index and $FFE;
  Result := Integer(FRegisters[Index]) + Integer(FRegisters[Index + 1]) * 256;
end;

procedure TAICADSP.WriteRegister(Address: Integer; Value: Byte);
begin
  if (Address >= $3000) and (Address < $4000) then
    FRegisters[Address - $3000] := Value;
end;

function TAICADSP.ReadRegister(Address: Integer): Byte;
begin
  Result := 0;
  if (Address >= $3000) and (Address < $4000) then
    Exit(FRegisters[Address - $3000]);
  var Value := 0;
  var Offset := Address and 7;
  if (Address >= $4000) and (Address < $4400) then
    Value := FTemp[(Address - $4000) div 8]
  else if (Address >= $4400) and (Address < $4500) then
    Value := FMemory[(Address - $4400) div 8]
  else if (Address >= $4500) and (Address < $4580) then
    Value := FMix[(Address - $4500) div 8]
  else if (Address >= $4580) and (Address < $45C0) then
  begin
    Value := FEffects[(Address - $4580) div 4];
    Offset := (Address and 3) + 4;
  end;
  if Offset in [0, 1] then
    Result := (Value shr (16 + Offset * 8)) and 255
  else if Offset in [4, 5] then
    Result := (Value shr ((Offset - 4) * 8)) and 255;
end;

procedure TAICADSP.Mix(Channel, Sample: Integer);
begin
  FMix[Channel and 15] := SignedBits(Int64(FMix[Channel and 15]) + Sample, 20);
end;

function TAICADSP.Effect(Channel: Integer): Integer;
begin
  Result := FEffects[Channel and 15];
end;

procedure TAICADSP.Step;
begin
  FillChar(FEffects, SizeOf(FEffects), 0);
  var Acc := 0;
  var MemoryValue := 0;
  var Fraction := 0;
  var YReg := 0;
  var AddressReg := 0;
  for var Index := 0 to 127 do
  begin
    var P := $400 + Index * 16;
    var I0 := WordAt(P);
    var I1 := WordAt(P + 4);
    var I2 := WordAt(P + 8);
    var I3 := WordAt(P + 12);
    var ReadTemp := (I0 shr 9) and 127;
    var WriteTemp := (I0 shr 1) and 127;
    var InputIndex := (I1 shr 7) and 63;
    var Input := 0;
    if InputIndex < 32 then
      Input := FMemory[InputIndex]
    else if InputIndex < 48 then
      Input := SignedBits(Int64(FMix[InputIndex - 32]) * 16, 24);
    if I1 and $40 <> 0 then
    begin
      var IW := (I1 shr 1) and 31;
      FMemory[IW] := MemoryValue;
      if InputIndex = IW then
        Input := MemoryValue;
    end;
    var B := 0;
    if I2 and 2 = 0 then
    begin
      if I2 and 1 <> 0 then
        B := Acc
      else
        B := FTemp[(ReadTemp + FDelay) and 127];
      if I2 and 4 <> 0 then
        B := -B;
    end;
    var X := Input;
    if I1 and $8000 = 0 then
      X := FTemp[(ReadTemp + FDelay) and 127];
    var Y := 0;
    case (I1 shr 13) and 3 of
      0:
        Y := Fraction;
      1:
        Y := Sar(SignedBits(WordAt(Index * 4), 16), 3);
      2:
        Y := (YReg shr 11) and $1FFF;
      3:
        Y := (YReg shr 4) and $FFF;
    end;
    Y := SignedBits(Y, 13);
    if I2 and 8 <> 0 then
      YReg := Input;
    var Shift := (I2 shr 4) and 3;
    var Shifted := 0;
    case Shift of
      0:
        Shifted := EnsureRange(Acc, -$800000, $7FFFFF);
      1:
        Shifted := EnsureRange(Int64(Acc) * 2, -$800000, $7FFFFF);
      2:
        Shifted := SignedBits(Int64(Acc) * 2, 24);
      3:
        Shifted := SignedBits(Acc, 24);
    end;
    Acc := SignedBits(Int64(Sar(Int64(X) * Y, 12)) + B, 26);
    if I0 and $100 <> 0 then
      FTemp[(WriteTemp + FDelay) and 127] := Shifted;
    if I2 and $40 <> 0 then
      if Shift = 3 then
        Fraction := Shifted and $FFF
      else
        Fraction := (Shifted shr 11) and $1FFF;
    if I2 and $6000 <> 0 then
    begin
      var Address := WordAt($200 + ((I3 shr 9) and 31) * 4);
      if I2 and $8000 = 0 then
        Inc(Address, FDelay);
      if I3 and $100 <> 0 then
        Inc(Address, AddressReg and $FFF);
      if I3 and $80 <> 0 then
        Inc(Address);
      if I2 and $8000 = 0 then
        Address := Address and (RingLength - 1)
      else
        Address := Address and $FFFF;
      Address := (Address * 2 + RingBase * 2048) and $7FFFFF;
      if Index and 1 <> 0 then
      begin
        if I2 and $2000 <> 0 then
        begin
          var V := Integer(FRead(Address)) + Integer(FRead((Address + 1) and $7FFFFF)) * 256;
          if I3 and $8000 <> 0 then
            MemoryValue := SignedBits(V, 16) * 256
          else
            MemoryValue := Unpack(V);
        end;
        if I2 and $4000 <> 0 then
        begin
          var V: Word;
          if I3 and $8000 <> 0 then
            V := Sar(Shifted, 8) and $FFFF
          else
            V := Pack(Shifted);
          FWrite(Address, V and 255);
          FWrite((Address + 1) and $7FFFFF, (V shr 8) and 255);
        end;
      end;
    end;
    if I2 and $80 <> 0 then
      if Shift = 3 then
        AddressReg := (Shifted shr 12) and $FFF
      else
        AddressReg := Sar(Input, 16);
    if I2 and $1000 <> 0 then
    begin
      var E := (I2 shr 8) and 15;
      FEffects[E] := SignedBits(Integer(FEffects[E]) + Sar(Shifted, 8), 16);
    end;
  end;
  FDelay := (FDelay - 1) and $FFFF;
  FillChar(FMix, SizeOf(FMix), 0);
end;

end.

