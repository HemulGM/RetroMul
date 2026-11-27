unit RA.AES128;

interface

type
  TRAAESBlock = array[0..15] of Byte;

  TRAAES128 = record
  private
    FRoundKeys: array[0..10] of TRAAESBlock;
    function Encrypt(const Block: TRAAESBlock): TRAAESBlock;
    function Decrypt(const Block: TRAAESBlock): TRAAESBlock;
  public
    procedure SetKey(const Key: TRAAESBlock);
    // Both modes update the IV for the next block. CBC requires complete blocks.
    procedure ApplyCTR(var Counter: TRAAESBlock; Data: PByte; Count: Integer);
    procedure DecryptCBC(var IV: TRAAESBlock; Data: PByte; Count: Integer);
  end;

implementation

uses
  System.Math, System.SysUtils;

const
  SBox: array[Byte] of Byte = (
    $63, $7C, $77, $7B, $F2, $6B, $6F, $C5, $30, $01, $67, $2B, $FE, $D7, $AB, $76,
    $CA, $82, $C9, $7D, $FA, $59, $47, $F0, $AD, $D4, $A2, $AF, $9C, $A4, $72, $C0,
    $B7, $FD, $93, $26, $36, $3F, $F7, $CC, $34, $A5, $E5, $F1, $71, $D8, $31, $15,
    $04, $C7, $23, $C3, $18, $96, $05, $9A, $07, $12, $80, $E2, $EB, $27, $B2, $75,
    $09, $83, $2C, $1A, $1B, $6E, $5A, $A0, $52, $3B, $D6, $B3, $29, $E3, $2F, $84,
    $53, $D1, $00, $ED, $20, $FC, $B1, $5B, $6A, $CB, $BE, $39, $4A, $4C, $58, $CF,
    $D0, $EF, $AA, $FB, $43, $4D, $33, $85, $45, $F9, $02, $7F, $50, $3C, $9F, $A8,
    $51, $A3, $40, $8F, $92, $9D, $38, $F5, $BC, $B6, $DA, $21, $10, $FF, $F3, $D2,
    $CD, $0C, $13, $EC, $5F, $97, $44, $17, $C4, $A7, $7E, $3D, $64, $5D, $19, $73,
    $60, $81, $4F, $DC, $22, $2A, $90, $88, $46, $EE, $B8, $14, $DE, $5E, $0B, $DB,
    $E0, $32, $3A, $0A, $49, $06, $24, $5C, $C2, $D3, $AC, $62, $91, $95, $E4, $79,
    $E7, $C8, $37, $6D, $8D, $D5, $4E, $A9, $6C, $56, $F4, $EA, $65, $7A, $AE, $08,
    $BA, $78, $25, $2E, $1C, $A6, $B4, $C6, $E8, $DD, $74, $1F, $4B, $BD, $8B, $8A,
    $70, $3E, $B5, $66, $48, $03, $F6, $0E, $61, $35, $57, $B9, $86, $C1, $1D, $9E,
    $E1, $F8, $98, $11, $69, $D9, $8E, $94, $9B, $1E, $87, $E9, $CE, $55, $28, $DF,
    $8C, $A1, $89, $0D, $BF, $E6, $42, $68, $41, $99, $2D, $0F, $B0, $54, $BB, $16
  );
  InverseSBox: array[Byte] of Byte = (
    $52, $09, $6A, $D5, $30, $36, $A5, $38, $BF, $40, $A3, $9E, $81, $F3, $D7, $FB,
    $7C, $E3, $39, $82, $9B, $2F, $FF, $87, $34, $8E, $43, $44, $C4, $DE, $E9, $CB,
    $54, $7B, $94, $32, $A6, $C2, $23, $3D, $EE, $4C, $95, $0B, $42, $FA, $C3, $4E,
    $08, $2E, $A1, $66, $28, $D9, $24, $B2, $76, $5B, $A2, $49, $6D, $8B, $D1, $25,
    $72, $F8, $F6, $64, $86, $68, $98, $16, $D4, $A4, $5C, $CC, $5D, $65, $B6, $92,
    $6C, $70, $48, $50, $FD, $ED, $B9, $DA, $5E, $15, $46, $57, $A7, $8D, $9D, $84,
    $90, $D8, $AB, $00, $8C, $BC, $D3, $0A, $F7, $E4, $58, $05, $B8, $B3, $45, $06,
    $D0, $2C, $1E, $8F, $CA, $3F, $0F, $02, $C1, $AF, $BD, $03, $01, $13, $8A, $6B,
    $3A, $91, $11, $41, $4F, $67, $DC, $EA, $97, $F2, $CF, $CE, $F0, $B4, $E6, $73,
    $96, $AC, $74, $22, $E7, $AD, $35, $85, $E2, $F9, $37, $E8, $1C, $75, $DF, $6E,
    $47, $F1, $1A, $71, $1D, $29, $C5, $89, $6F, $B7, $62, $0E, $AA, $18, $BE, $1B,
    $FC, $56, $3E, $4B, $C6, $D2, $79, $20, $9A, $DB, $C0, $FE, $78, $CD, $5A, $F4,
    $1F, $DD, $A8, $33, $88, $07, $C7, $31, $B1, $12, $10, $59, $27, $80, $EC, $5F,
    $60, $51, $7F, $A9, $19, $B5, $4A, $0D, $2D, $E5, $7A, $9F, $93, $C9, $9C, $EF,
    $A0, $E0, $3B, $4D, $AE, $2A, $F5, $B0, $C8, $EB, $BB, $3C, $83, $53, $99, $61,
    $17, $2B, $04, $7E, $BA, $77, $D6, $26, $E1, $69, $14, $63, $55, $21, $0C, $7D
  );

function DoubleByte(Value: Byte): Byte; inline;
begin
  Result := Byte((Value shl 1) and $FF);
  if (Value and $80) <> 0 then
    Result := Result xor $1B;
end;

procedure TRAAES128.SetKey(const Key: TRAAESBlock);
var
  Previous, Next: TRAAESBlock;
  RoundConstant: Byte;
begin
  FRoundKeys[0] := Key;
  RoundConstant := 1;
  for var Round := 1 to High(FRoundKeys) do
  begin
    Previous := FRoundKeys[Round - 1];
    Next[0] := Previous[0] xor SBox[Previous[13]] xor RoundConstant;
    Next[1] := Previous[1] xor SBox[Previous[14]];
    Next[2] := Previous[2] xor SBox[Previous[15]];
    Next[3] := Previous[3] xor SBox[Previous[12]];
    for var I := 4 to High(Next) do
      Next[I] := Previous[I] xor Next[I - 4];
    FRoundKeys[Round] := Next;
    RoundConstant := DoubleByte(RoundConstant);
  end;
end;

procedure AddRoundKey(var State: TRAAESBlock; const Key: TRAAESBlock); inline;
begin
  for var I := 0 to High(State) do
    State[I] := State[I] xor Key[I];
end;

procedure SubstituteAndShift(var State: TRAAESBlock; Inverse: Boolean);
var
  Shifted: TRAAESBlock;
  Column, Row: Integer;
begin
  if Inverse then
    for Column := 0 to 3 do
      for Row := 0 to 3 do
        Shifted[Column * 4 + Row] := InverseSBox[State[((Column + 4 - Row) and 3) * 4 + Row]]
  else
    for Column := 0 to 3 do
      for Row := 0 to 3 do
        Shifted[Column * 4 + Row] := SBox[State[((Column + Row) and 3) * 4 + Row]];
  State := Shifted;
end;

procedure MixColumns(var State: TRAAESBlock; Inverse: Boolean);
var
  I: Integer;
  A, B, C, D, Sum, Even, Odd: Byte;
begin
  for var Column := 0 to 3 do
  begin
    I := Column * 4;
    A := State[I];
    B := State[I + 1];
    C := State[I + 2];
    D := State[I + 3];
    if Inverse then
    begin
      // Factor the inverse matrix into a simple transform and the forward matrix.
      Even := DoubleByte(DoubleByte(A xor C));
      Odd := DoubleByte(DoubleByte(B xor D));
      A := A xor Even;
      B := B xor Odd;
      C := C xor Even;
      D := D xor Odd;
    end;
    Sum := A xor B xor C xor D;
    State[I] := A xor Sum xor DoubleByte(A xor B);
    State[I + 1] := B xor Sum xor DoubleByte(B xor C);
    State[I + 2] := C xor Sum xor DoubleByte(C xor D);
    State[I + 3] := D xor Sum xor DoubleByte(D xor A);
  end;
end;

function TRAAES128.Encrypt(const Block: TRAAESBlock): TRAAESBlock;
begin
  Result := Block;
  AddRoundKey(Result, FRoundKeys[0]);
  for var Round := 1 to 9 do
  begin
    SubstituteAndShift(Result, False);
    MixColumns(Result, False);
    AddRoundKey(Result, FRoundKeys[Round]);
  end;
  SubstituteAndShift(Result, False);
  AddRoundKey(Result, FRoundKeys[10]);
end;

function TRAAES128.Decrypt(const Block: TRAAESBlock): TRAAESBlock;
begin
  Result := Block;
  AddRoundKey(Result, FRoundKeys[10]);
  for var Round := 9 downto 1 do
  begin
    SubstituteAndShift(Result, True);
    AddRoundKey(Result, FRoundKeys[Round]);
    MixColumns(Result, True);
  end;
  SubstituteAndShift(Result, True);
  AddRoundKey(Result, FRoundKeys[0]);
end;

procedure TRAAES128.ApplyCTR(var Counter: TRAAESBlock; Data: PByte; Count: Integer);
var
  KeyStream: TRAAESBlock;
  Size: Integer;
begin
  while Count > 0 do
  begin
    KeyStream := Encrypt(Counter);
    for var I := High(Counter) downto 0 do
    begin
      Counter[I] := Byte((Integer(Counter[I]) + 1) and $FF);
      if Counter[I] <> 0 then
        Break;
    end;
    Size := Min(Count, SizeOf(KeyStream));
    for var I := 0 to Size - 1 do
      Data[I] := Data[I] xor KeyStream[I];
    Dec(Count, Size);
    Inc(Data, Size);
  end;
end;

procedure TRAAES128.DecryptCBC(var IV: TRAAESBlock; Data: PByte; Count: Integer);
var
  Block, Plain: TRAAESBlock;
begin
  if (Count < 0) or (Count mod SizeOf(Block) <> 0) then
    raise EArgumentException.Create('AES-CBC data must use complete blocks');

  while Count > 0 do
  begin
    Move(Data^, Block, SizeOf(Block));
    Plain := Decrypt(Block);
    for var I := 0 to High(Plain) do
      Data[I] := Plain[I] xor IV[I];
    IV := Block;
    Dec(Count, SizeOf(Block));
    Inc(Data, SizeOf(Block));
  end;
end;

end.
