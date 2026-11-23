unit S16.Crypto;

interface

uses
  System.SysUtils;

function FD1089(Address, Value: Cardinal; const MainKey: TBytes; Opcode, VariantB: Boolean): Word;

function FD1094(Address, Val: Cardinal; const MainKey: TBytes; State: Byte; Vector_Fetch: Boolean): Word;

function MC8123(Address, Value: Cardinal; const MainKey: TBytes; Opcode: Boolean): Byte;

function Sega3155177(Address: Word; Value: Byte; Opcode: Boolean): Byte;

implementation

type
  TDecryptParams = array[0..8] of Cardinal;

var
  Masked: array[0..1, 0..$7FFF] of Boolean;

function BIT(Value, Shift: Cardinal): Cardinal; inline;
begin
  Result := (Value shr Shift) and 1;
end;

function SwapBits(Value: Cardinal; const Order: array of Integer): Cardinal;
begin
  Result := 0;
  for var I := 0 to High(Order) do
    Result := (Result shl 1) or ((Value shr Order[I]) and 1);
end;

const
  BaseTable: array[0..255] of Byte = (
    $00, $1c, $76, $6a, $5e, $42, $24, $38, $4b, $67, $ad, $81, $e9, $c5, $03, $2f,
    $45, $69, $af, $83, $e7, $cb, $01, $2d, $02, $1e, $78, $64, $5c, $40, $2a, $36,
    $32, $2e, $44, $58, $e4, $f8, $9e, $82, $29, $05, $cf, $e3, $93, $bf, $79, $55,
    $3f, $13, $d5, $f9, $85, $a9, $63, $4f, $b8, $a4, $c2, $de, $6e, $72, $18, $04,
    $0c, $10, $7a, $66, $fc, $e0, $86, $9a, $47, $6b, $a1, $8d, $bb, $97, $51, $7d,
    $17, $3b, $fd, $d1, $eb, $c7, $0d, $21, $a0, $bc, $da, $c6, $50, $4c, $26, $3a,
    $3e, $22, $48, $54, $46, $5a, $3c, $20, $25, $09, $c3, $ef, $c1, $ed, $2b, $07,
    $6d, $41, $87, $ab, $89, $a5, $6f, $43, $1a, $06, $60, $7c, $62, $7e, $14, $08,
    $0a, $16, $70, $6c, $dc, $c0, $aa, $b6, $4d, $61, $a7, $8b, $f7, $db, $11, $3d,
    $5b, $77, $bd, $91, $e1, $cd, $0b, $27, $80, $9c, $f6, $ea, $56, $4a, $2c, $30,
    $b0, $ac, $ca, $d6, $ee, $f2, $98, $84, $37, $1b, $dd, $f1, $95, $b9, $73, $5f,
    $39, $15, $df, $f3, $9b, $b7, $71, $5d, $b2, $ae, $c4, $d8, $ec, $f0, $96, $8a,
    $a8, $b4, $d2, $ce, $d0, $cc, $a6, $ba, $1f, $33, $f5, $d9, $fb, $d7, $1d, $31,
    $57, $7b, $b1, $9d, $b3, $9f, $59, $75, $8c, $90, $fa, $e6, $f4, $e8, $8e, $92,
    $12, $0e, $68, $74, $e2, $fe, $94, $88, $65, $49, $8f, $a3, $99, $b5, $7f, $53,
    $35, $19, $d3, $ff, $c9, $e5, $23, $0f, $be, $a2, $c8, $d4, $4e, $52, $34, $28
  );
  AddrParams: array[0..15] of TDecryptParams = (
    ($23, 6, 4, 5, 7, 3, 0, 1, 2),
    ($92, 2, 5, 3, 6, 7, 1, 0, 4),
    ($b8, 6, 7, 4, 2, 0, 5, 1, 3),
    ($74, 5, 3, 7, 1, 4, 6, 0, 2),
    ($cf, 7, 4, 1, 0, 6, 2, 3, 5),
    ($c4, 3, 1, 6, 4, 5, 0, 2, 7),
    ($51, 5, 7, 2, 4, 3, 1, 6, 0),
    ($14, 7, 2, 0, 6, 1, 3, 4, 5),
    ($7f, 3, 5, 6, 0, 2, 1, 7, 4),
    ($03, 2, 3, 4, 0, 6, 7, 5, 1),
    ($96, 3, 1, 7, 5, 2, 4, 6, 0),
    ($30, 7, 6, 2, 3, 0, 4, 5, 1),
    ($e2, 1, 0, 3, 7, 4, 5, 2, 6),
    ($72, 1, 6, 0, 5, 7, 2, 4, 3),
    ($f5, 0, 4, 1, 2, 6, 5, 7, 3),
    ($5b, 0, 7, 5, 3, 1, 4, 2, 6)
  );
  DataParams: array[0..15] of TDecryptParams = (
    ($55, 6, 5, 1, 0, 7, 4, 2, 3),
    ($94, 7, 6, 4, 2, 0, 5, 1, 3),
    ($8d, 1, 4, 2, 3, 0, 6, 7, 5),
    ($9a, 4, 3, 5, 6, 0, 2, 1, 7),
    ($72, 4, 3, 7, 0, 5, 6, 1, 2),
    ($ff, 1, 7, 2, 3, 6, 4, 5, 0),
    ($06, 6, 5, 3, 2, 4, 1, 0, 7),
    ($c5, 3, 5, 1, 4, 2, 7, 0, 6),
    ($ec, 4, 7, 5, 1, 6, 0, 2, 3),
    ($89, 3, 5, 0, 6, 1, 2, 7, 4),
    ($5c, 1, 3, 0, 7, 5, 2, 4, 6),
    ($3f, 7, 3, 0, 2, 4, 6, 1, 5),
    ($57, 6, 4, 7, 2, 1, 5, 3, 0),
    ($f7, 6, 3, 7, 0, 5, 4, 2, 1),
    ($3a, 6, 1, 3, 2, 7, 4, 5, 0),
    ($ac, 1, 6, 3, 5, 0, 7, 4, 2)
  );

function RearrangeKey(Table: Cardinal; Opcode: Boolean): Cardinal;
begin
  if (not Opcode) then
  begin
    Table := (Table xor (1 shl 4));
    Table := (Table xor (1 shl 5));
    if (BIT((not Table), 3) <> 0) then
    begin
      Table := (Table xor (1 shl 1));
    end;
    Table := SwapBits(Table, [1, 0, 6, 4, 3, 5, 2, 7]);
    if (BIT(Table, 6) <> 0) then
    begin
      Table := SwapBits(Table, [7, 6, 2, 4, 5, 3, 1, 0]);
    end;
  end
  else
  begin
    Table := (Table xor (1 shl 2));
    Table := (Table xor (1 shl 3));
    Table := (Table xor (1 shl 4));
    if (BIT((not Table), 3) <> 0) then
    begin
      Table := (Table xor (1 shl 5));
    end;
    if (BIT(Table, 7) <> 0) then
    begin
      Table := (Table xor (1 shl 6));
    end;
    Table := SwapBits(Table, [5, 7, 6, 4, 2, 3, 1, 0]);
    if (BIT(Table, 6) <> 0) then
    begin
      Table := SwapBits(Table, [7, 6, 5, 3, 2, 4, 1, 0]);
    end;
  end;
  if (BIT(Table, 6) <> 0) then
  begin
    if (BIT(Table, 5) <> 0) then
    begin
      Table := (Table xor (1 shl 4));
    end;
  end
  else
  begin
    if (BIT((not Table), 4) <> 0) then
    begin
      Table := (Table xor (1 shl 5));
    end;
  end;
  Exit(Table);
end;

function Decode1089A(Val, Key: Cardinal; Opcode: Boolean): Cardinal;
begin
  if (Key = $00) then
  begin
    Exit(Val);
  end;
  var table: Cardinal;
  table := RearrangeKey(Key, Opcode);
  var p: TDecryptParams;
  p := AddrParams[(table shr 4)];
  Val := (SwapBits(Val, [p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8]]) xor p[0]);
  if (BIT(table, 3) <> 0) then
  begin
    Val := (Val xor $01);
  end;
  if (BIT(table, 0) <> 0) then
  begin
    Val := (Val xor $b1);
  end;
  if Opcode then
  begin
    Val := (Val xor $34);
  end;
  if (not Opcode) then
  begin
    if (BIT(table, 6) <> 0) then
    begin
      Val := (Val xor $01);
    end;
  end;
  Val := BaseTable[Val];
  var family: Cardinal;
  family := (table and $07);
  if (not Opcode) then
  begin
    if ((BIT((not table), 6) and BIT(table, 2)) <> 0) then
    begin
      family := (family xor 8);
    end;
    if (BIT(table, 4) <> 0) then
    begin
      family := (family xor 8);
    end;
  end
  else
  begin
    if ((BIT(table, 6) and BIT(table, 2)) <> 0) then
    begin
      family := (family xor 8);
    end;
    if (BIT(table, 5) <> 0) then
    begin
      family := (family xor 8);
    end;
  end;
  if (BIT(table, 0) <> 0) then
  begin
    if (BIT(Val, 0) <> 0) then
    begin
      Val := (Val xor $c0);
    end;
    if ((BIT((not Val), 6) xor BIT(Val, 4)) <> 0) then
    begin
      Val := SwapBits(Val, [7, 6, 5, 4, 1, 0, 2, 3]);
    end;
  end
  else
  begin
    if ((BIT((not Val), 6) xor BIT(Val, 4)) <> 0) then
    begin
      Val := SwapBits(Val, [7, 6, 5, 4, 0, 1, 3, 2]);
    end;
  end;
  if (BIT((not Val), 6) <> 0) then
  begin
    Val := SwapBits(Val, [7, 6, 5, 4, 2, 3, 0, 1]);
  end;
  var q: TDecryptParams;
  q := DataParams[family];
  Val := (Val xor q[0]);
  Val := SwapBits(Val, [q[1], q[2], q[3], q[4], q[5], q[6], q[7], q[8]]);
  Exit(Val);
end;

function Decode1089B(Val, Key: Cardinal; Opcode: Boolean): Cardinal;
begin
  if (Key = $00) then
  begin
    Exit(Val);
  end;
  var table: Cardinal;
  table := RearrangeKey(Key, Opcode);
  var p: TDecryptParams;
  p := AddrParams[(table shr 4)];
  Val := (SwapBits(Val, [p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8]]) xor p[0]);
  if (BIT(table, 3) <> 0) then
  begin
    Val := (Val xor $01);
  end;
  if (BIT(table, 0) <> 0) then
  begin
    Val := (Val xor $b1);
  end;
  if Opcode then
  begin
    Val := (Val xor $34);
  end;
  if (not Opcode) then
  begin
    if (BIT(table, 6) <> 0) then
    begin
      Val := (Val xor $01);
    end;
  end;
  Val := BaseTable[Val];
  var xorval: Cardinal;
  xorval := 0;
  if (not Opcode) then
  begin
    if ((BIT((not table), 6) and BIT(table, 2)) <> 0) then
    begin
      xorval := (xorval xor $01);
    end;
    if (BIT(table, 4) <> 0) then
    begin
      xorval := (xorval xor $01);
    end;
  end
  else
  begin
    if ((BIT(table, 6) and BIT(table, 2)) <> 0) then
    begin
      xorval := (xorval xor $01);
    end;
    if (BIT(table, 5) <> 0) then
    begin
      xorval := (xorval xor $01);
    end;
  end;
  Val := (Val xor xorval);
  if (BIT(table, 2) <> 0) then
  begin
    Val := SwapBits(Val, [7, 6, 5, 4, 1, 0, 3, 2]);
    if ((BIT(table, 0) xor BIT(table, 1)) <> 0) then
    begin
      Val := SwapBits(Val, [7, 6, 5, 4, 0, 1, 3, 2]);
    end;
  end
  else
  begin
    Val := SwapBits(Val, [7, 6, 5, 4, 3, 2, 0, 1]);
    if ((BIT(table, 0) xor BIT(table, 1)) <> 0) then
    begin
      Val := SwapBits(Val, [7, 6, 5, 4, 1, 0, 2, 3]);
    end;
  end;
  Exit(Val);
end;

function FD1089(Address, Value: Cardinal; const MainKey: TBytes; Opcode, VariantB: Boolean): Word;
begin
  var Index := ((Address and $2) shr 1) or ((Address and $8) shr 2) or
    ((Address and $20) shr 3) or ((Address and $200) shr 6) or ((Address and $FF0000) shr 12);
  var Src := ((Value and $8) shr 3) or ((Value and $40) shr 5) or ((Value and $FC00) shr 8);
  if not Opcode then
    Inc(Index, $1000);
  if VariantB then
    Src := Decode1089B(Src, MainKey[Index], Opcode)
  else
    Src := Decode1089A(Src, MainKey[Index], Opcode);
  Src := ((Src and 1) shl 3) or ((Src and 2) shl 5) or ((Src and $FC) shl 8);
  Result := Word((Value and $3B7) or Src);
end;

function FD1094(Address, Val: Cardinal; const MainKey: TBytes; State: Byte; Vector_Fetch: Boolean): Word;
begin
  var gkey1: Cardinal;
  gkey1 := MainKey[1];
  var gkey2: Cardinal;
  gkey2 := MainKey[2];
  var gkey3: Cardinal;
  gkey3 := MainKey[3];
  if ((State and $0001) <> 0) then
  begin
    gkey1 := (gkey1 xor $04);
    gkey2 := (gkey2 xor $80);
    gkey3 := (gkey3 xor $80);
  end;
  if ((State and $0002) <> 0) then
  begin
    gkey1 := (gkey1 xor $01);
    gkey2 := (gkey2 xor $10);
    gkey3 := (gkey3 xor $01);
  end;
  if ((State and $0004) <> 0) then
  begin
    gkey1 := (gkey1 xor $80);
    gkey2 := (gkey2 xor $40);
    gkey3 := (gkey3 xor $04);
  end;
  if ((State and $0008) <> 0) then
  begin
    gkey1 := (gkey1 xor $20);
    gkey2 := (gkey2 xor $02);
    gkey3 := (gkey3 xor $20);
  end;
  if ((State and $0010) <> 0) then
  begin
    gkey1 := (gkey1 xor $02);
    gkey1 := (gkey1 xor $40);
    gkey2 := (gkey2 xor $08);
  end;
  if ((State and $0020) <> 0) then
  begin
    gkey1 := (gkey1 xor $08);
    gkey3 := (gkey3 xor $08);
    gkey3 := (gkey3 xor $10);
  end;
  if ((State and $0040) <> 0) then
  begin
    gkey1 := (gkey1 xor $10);
    gkey2 := (gkey2 xor $20);
    gkey2 := (gkey2 xor $04);
  end;
  if ((State and $0080) <> 0) then
  begin
    gkey2 := (gkey2 xor $01);
    gkey3 := (gkey3 xor $02);
    gkey3 := (gkey3 xor $40);
  end;
  var MainByte: Cardinal;
  if (((Address and $0ffc) = 0) and (Address >= 4)) then
  begin
    MainByte := MainKey[((Address and $1fff) or $1000)];
  end
  else
  begin
    MainByte := MainKey[(Address and $1fff)];
  end;
  var key_F: Cardinal;
  if ((Address and $1000) <> 0) then
  begin
    key_F := BIT(MainByte, 7);
  end
  else
  begin
    key_F := BIT(MainByte, 6);
  end;
  if Vector_Fetch then
  begin
    if (Address <= 3) then
    begin
      gkey3 := $00;
    end;
    if (Address <= 2) then
    begin
      gkey2 := $00;
    end;
    if (Address <= 1) then
    begin
      gkey1 := $00;
    end;
    if (Address <= 1) then
    begin
      key_F := 0;
    end;
  end;
  var global_xor0: Cardinal;
  global_xor0 := (1 xor BIT(gkey1, 5));
  var global_xor1: Cardinal;
  global_xor1 := (1 xor BIT(gkey1, 2));
  var global_swap2: Cardinal;
  global_swap2 := (1 xor BIT(gkey1, 0));
  var global_swap0a: Cardinal;
  global_swap0a := (1 xor BIT(gkey2, 5));
  var global_swap0b: Cardinal;
  global_swap0b := (1 xor BIT(gkey2, 2));
  var global_swap3: Cardinal;
  global_swap3 := (1 xor BIT(gkey3, 6));
  var global_swap1: Cardinal;
  global_swap1 := (1 xor BIT(gkey3, 4));
  var global_swap4: Cardinal;
  global_swap4 := (1 xor BIT(gkey3, 2));
  var key_0a: Cardinal;
  key_0a := (BIT(MainByte, 0) xor BIT(gkey3, 1));
  var key_0b: Cardinal;
  key_0b := (BIT(MainByte, 0) xor BIT(gkey1, 7));
  var key_0c: Cardinal;
  key_0c := (BIT(MainByte, 0) xor BIT(gkey1, 1));
  var key_1a: Cardinal;
  key_1a := (BIT(MainByte, 1) xor BIT(gkey2, 7));
  var key_1b: Cardinal;
  key_1b := (BIT(MainByte, 1) xor BIT(gkey1, 3));
  var key_2a: Cardinal;
  key_2a := (BIT(MainByte, 2) xor BIT(gkey3, 7));
  var key_2b: Cardinal;
  key_2b := (BIT(MainByte, 2) xor BIT(gkey1, 4));
  var key_3a: Cardinal;
  key_3a := (BIT(MainByte, 3) xor BIT(gkey2, 0));
  var key_3b: Cardinal;
  key_3b := (BIT(MainByte, 3) xor BIT(gkey3, 3));
  var key_4a: Cardinal;
  key_4a := (BIT(MainByte, 4) xor BIT(gkey2, 3));
  var key_4b: Cardinal;
  key_4b := (BIT(MainByte, 4) xor BIT(gkey3, 0));
  var key_5a: Cardinal;
  key_5a := (BIT(MainByte, 5) xor BIT(gkey3, 5));
  var key_5b: Cardinal;
  key_5b := (BIT(MainByte, 5) xor BIT(gkey1, 6));
  var key_6a: Cardinal;
  key_6a := (BIT(MainByte, 6) xor BIT(gkey2, 1));
  var key_6b: Cardinal;
  key_6b := (BIT(MainByte, 6) xor BIT(gkey2, 6));
  var key_7a: Cardinal;
  key_7a := (BIT(MainByte, 7) xor BIT(gkey2, 4));
  if ((Val and $8000) <> 0) then
  begin
    Val := SwapBits(Val, [15, 9, 10, 13, 3, 12, 0, 14, 6, 5, 2, 11, 8, 1, 4, 7]);
    if (not (global_xor1 <> 0)) then
    begin
      if (((not Val) and $0800) <> 0) then
      begin
        Val := (Val xor $3002);
      end;
    end;
    if True then
    begin
      if (((not Val) and $0020) <> 0) then
      begin
        Val := (Val xor $0044);
      end;
    end;
    if (not (key_1b <> 0)) then
    begin
      if (((not Val) and $0400) <> 0) then
      begin
        Val := (Val xor $0890);
      end;
    end;
    if (not (global_swap2 <> 0)) then
    begin
      if (not (key_0c <> 0)) then
      begin
        Val := (Val xor $0308);
      end;
    end;
    Val := (Val xor $6561);
    if (not (key_2b <> 0)) then
    begin
      Val := SwapBits(Val, [15, 10, 13, 12, 11, 14, 9, 8, 7, 6, 0, 4, 3, 2, 1, 5]);
    end;
  end;
  if ((Val and $4000) <> 0) then
  begin
    Val := SwapBits(Val, [13, 14, 7, 0, 8, 6, 4, 2, 1, 15, 3, 11, 12, 10, 5, 9]);
    if (not (global_xor0 <> 0)) then
    begin
      if ((Val and $0010) <> 0) then
      begin
        Val := (Val xor $0468);
      end;
    end;
    if (not (key_3a <> 0)) then
    begin
      if ((Val and $0100) <> 0) then
      begin
        Val := (Val xor $0081);
      end;
    end;
    if (not (key_6a <> 0)) then
    begin
      if ((Val and $0004) <> 0) then
      begin
        Val := (Val xor $0100);
      end;
    end;
    if (not (key_5b <> 0)) then
    begin
      if (not (key_0b <> 0)) then
      begin
        Val := (Val xor $3012);
      end;
    end;
    Val := (Val xor $3523);
    if (not (global_swap0b <> 0)) then
    begin
      Val := SwapBits(Val, [2, 14, 13, 12, 9, 10, 11, 8, 7, 6, 5, 4, 3, 15, 1, 0]);
    end;
  end;
  if ((Val and $2000) <> 0) then
  begin
    Val := SwapBits(Val, [10, 2, 13, 7, 8, 0, 3, 14, 6, 15, 1, 11, 9, 4, 5, 12]);
    if (not (key_4a <> 0)) then
    begin
      if ((Val and $0800) <> 0) then
      begin
        Val := (Val xor $010c);
      end;
    end;
    if (not (key_1a <> 0)) then
    begin
      if ((Val and $0080) <> 0) then
      begin
        Val := (Val xor $1000);
      end;
    end;
    if (not (key_7a <> 0)) then
    begin
      if ((Val and $0400) <> 0) then
      begin
        Val := (Val xor $0a21);
      end;
    end;
    if (not (key_4b <> 0)) then
    begin
      if (not (key_0a <> 0)) then
      begin
        Val := (Val xor $0080);
      end;
    end;
    if (not (global_swap0a <> 0)) then
    begin
      if (not (key_6b <> 0)) then
      begin
        Val := (Val xor $c000);
      end;
    end;
    Val := (Val xor $99a5);
    if (not (key_5b <> 0)) then
    begin
      Val := SwapBits(Val, [15, 14, 13, 12, 11, 1, 9, 8, 7, 10, 5, 6, 3, 2, 4, 0]);
    end;
  end;
  if ((Val and $e000) <> 0) then
  begin
    Val := SwapBits(Val, [15, 13, 14, 5, 6, 0, 9, 10, 4, 11, 1, 2, 12, 3, 7, 8]);
    Val := (Val xor $17ff);
    if (not (global_swap4 <> 0)) then
    begin
      Val := SwapBits(Val, [15, 14, 13, 6, 11, 10, 9, 5, 7, 12, 8, 4, 3, 2, 1, 0]);
    end;
    if (not (global_swap3 <> 0)) then
    begin
      Val := SwapBits(Val, [13, 15, 14, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]);
    end;
    if (not (global_swap2 <> 0)) then
    begin
      Val := SwapBits(Val, [15, 14, 13, 12, 11, 2, 9, 8, 10, 6, 5, 4, 3, 0, 1, 7]);
    end;
    if (not (key_3b <> 0)) then
    begin
      Val := SwapBits(Val, [15, 14, 13, 12, 11, 10, 4, 8, 7, 6, 5, 9, 1, 2, 3, 0]);
    end;
    if (not (key_2a <> 0)) then
    begin
      Val := SwapBits(Val, [13, 14, 15, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]);
    end;
    if (not (global_swap1 <> 0)) then
    begin
      Val := SwapBits(Val, [15, 14, 13, 12, 9, 8, 11, 10, 7, 6, 5, 4, 3, 2, 1, 0]);
    end;
    if (not (key_5a <> 0)) then
    begin
      Val := SwapBits(Val, [15, 14, 13, 12, 11, 10, 9, 8, 4, 5, 7, 6, 3, 2, 1, 0]);
    end;
    if (not (global_swap0a <> 0)) then
    begin
      Val := SwapBits(Val, [15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 0, 3, 2, 1]);
    end;
  end;
  Val := SwapBits(Val, [12, 15, 14, 13, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]);
  if ((Val and $b080) = $8000) then
  begin
    Val := (Val xor $4000);
  end;
  if ((Val and $f000) = $c000) then
  begin
    Val := (Val xor $0080);
  end;
  if ((Val and $b100) = $0000) then
  begin
    Val := (Val xor $4000);
  end;
  if (Ord(Masked[key_F, (Val shr 1)]) <> 0) then
  begin
    Val := $ffff;
  end;
  Exit(Val);
end;

function decrypt_type0(Val, Params, SwapMode: Cardinal): Cardinal;
begin
  if (SwapMode = 0) then
  begin
    Val := SwapBits(Val, [7, 5, 3, 1, 2, 0, 6, 4]);
  end;
  if (SwapMode = 1) then
  begin
    Val := SwapBits(Val, [5, 3, 7, 2, 1, 0, 4, 6]);
  end;
  if (SwapMode = 2) then
  begin
    Val := SwapBits(Val, [0, 3, 4, 6, 7, 1, 5, 2]);
  end;
  if (SwapMode = 3) then
  begin
    Val := SwapBits(Val, [0, 7, 3, 2, 6, 4, 1, 5]);
  end;
  if ((BIT(Params, 3) <> 0) and (BIT(Val, 7) <> 0)) then
  begin
    Val := (Val xor $29);
  end;
  if ((BIT(Params, 2) <> 0) and (BIT(Val, 6) <> 0)) then
  begin
    Val := (Val xor $86);
  end;
  if (BIT(Val, 6) <> 0) then
  begin
    Val := (Val xor $80);
  end;
  if ((BIT(Params, 1) <> 0) and (BIT(Val, 7) <> 0)) then
  begin
    Val := (Val xor $40);
  end;
  if (BIT(Val, 2) <> 0) then
  begin
    Val := (Val xor $21);
  end;
  Val := (Val xor $1A);
  if (BIT(Params, 2) <> 0) then
  begin
    Val := (Val xor $25);
  end;
  if (BIT(Params, 1) <> 0) then
  begin
    Val := (Val xor $C0);
  end;
  if (BIT(Params, 0) <> 0) then
  begin
    Val := (Val xor $21);
  end;
  if (BIT(Params, 0) <> 0) then
  begin
    Val := SwapBits(Val, [7, 6, 5, 1, 4, 3, 2, 0]);
  end;
  Exit(Val);
end;

function decrypt_type1a(Val, Params, SwapMode: Cardinal): Cardinal;
begin
  if (SwapMode = 0) then
  begin
    Val := SwapBits(Val, [4, 2, 6, 5, 3, 7, 1, 0]);
  end;
  if (SwapMode = 1) then
  begin
    Val := SwapBits(Val, [6, 0, 5, 4, 3, 2, 1, 7]);
  end;
  if (SwapMode = 2) then
  begin
    Val := SwapBits(Val, [2, 3, 6, 1, 4, 0, 7, 5]);
  end;
  if (SwapMode = 3) then
  begin
    Val := SwapBits(Val, [6, 5, 1, 3, 2, 7, 0, 4]);
  end;
  if (BIT(Params, 2) <> 0) then
  begin
    Val := SwapBits(Val, [7, 6, 1, 5, 3, 2, 4, 0]);
  end;
  if (BIT(Val, 1) <> 0) then
  begin
    Val := (Val xor $1);
  end;
  if (BIT(Val, 6) <> 0) then
  begin
    Val := (Val xor $8);
  end;
  if (BIT(Val, 7) <> 0) then
  begin
    Val := (Val xor $48);
  end;
  if (BIT(Val, 2) <> 0) then
  begin
    Val := (Val xor $4A);
  end;
  if (BIT(Val, 4) <> 0) then
  begin
    Val := (Val xor $C4);
  end;
  if ((BIT(Val, 7) xor BIT(Val, 2)) <> 0) then
  begin
    Val := (Val xor $10);
  end;
  Val := (Val xor $4B);
  if (BIT(Params, 3) <> 0) then
  begin
    Val := (Val xor $84);
  end;
  if (BIT(Params, 1) <> 0) then
  begin
    Val := (Val xor $48);
  end;
  if (BIT(Params, 0) <> 0) then
  begin
    Val := SwapBits(Val, [7, 6, 1, 4, 3, 2, 5, 0]);
  end;
  Exit(Val);
end;

function decrypt_type1b(Val, Params, SwapMode: Cardinal): Cardinal;
begin
  if (SwapMode = 0) then
  begin
    Val := SwapBits(Val, [1, 0, 3, 2, 5, 6, 4, 7]);
  end;
  if (SwapMode = 1) then
  begin
    Val := SwapBits(Val, [2, 0, 5, 1, 7, 4, 6, 3]);
  end;
  if (SwapMode = 2) then
  begin
    Val := SwapBits(Val, [6, 4, 7, 2, 0, 5, 1, 3]);
  end;
  if (SwapMode = 3) then
  begin
    Val := SwapBits(Val, [7, 1, 3, 6, 0, 2, 5, 4]);
  end;
  if ((BIT(Val, 2) <> 0) and (BIT(Val, 0) <> 0)) then
  begin
    Val := (Val xor $90);
  end;
  if (BIT(Val, 7) <> 0) then
  begin
    Val := (Val xor $4);
  end;
  if (BIT(Val, 5) <> 0) then
  begin
    Val := (Val xor $84);
  end;
  if (BIT(Val, 1) <> 0) then
  begin
    Val := (Val xor $20);
  end;
  if (BIT(Val, 6) <> 0) then
  begin
    Val := (Val xor $2);
  end;
  if (BIT(Val, 4) <> 0) then
  begin
    Val := (Val xor $60);
  end;
  if (BIT(Val, 0) <> 0) then
  begin
    Val := (Val xor $46);
  end;
  if (BIT(Val, 3) <> 0) then
  begin
    Val := (Val xor $C7);
  end;
  Val := (Val xor $51);
  if (BIT(Params, 3) <> 0) then
  begin
    Val := (Val xor $12);
  end;
  if (BIT(Params, 2) <> 0) then
  begin
    Val := (Val xor $C9);
  end;
  if (BIT(Params, 1) <> 0) then
  begin
    Val := (Val xor $18);
  end;
  if (BIT(Params, 0) <> 0) then
  begin
    Val := (Val xor $47);
  end;
  Exit(Val);
end;

function decrypt_type2a(Val, Params, SwapMode: Cardinal): Cardinal;
begin
  if (SwapMode = 0) then
  begin
    Val := SwapBits(Val, [0, 1, 4, 3, 5, 6, 2, 7]);
  end;
  if (SwapMode = 1) then
  begin
    Val := SwapBits(Val, [6, 3, 0, 5, 7, 4, 1, 2]);
  end;
  if (SwapMode = 2) then
  begin
    Val := SwapBits(Val, [1, 6, 4, 5, 0, 3, 7, 2]);
  end;
  if (SwapMode = 3) then
  begin
    Val := SwapBits(Val, [4, 6, 7, 5, 2, 3, 1, 0]);
  end;
  if ((BIT(Val, 3) <> 0) or ((BIT(Params, 1) <> 0) and (BIT(Val, 2) <> 0))) then
  begin
    Val := SwapBits(Val, [6, 0, 7, 4, 3, 2, 1, 5]);
  end;
  if (BIT(Val, 5) <> 0) then
  begin
    Val := (Val xor $80);
  end;
  if (BIT(Val, 6) <> 0) then
  begin
    Val := (Val xor $20);
  end;
  if (BIT(Val, 0) <> 0) then
  begin
    Val := (Val xor $40);
  end;
  if (BIT(Val, 4) <> 0) then
  begin
    Val := (Val xor $9);
  end;
  if (BIT(Val, 1) <> 0) then
  begin
    Val := (Val xor $4);
  end;
  Val := (Val xor $F2);
  if (BIT(Params, 2) <> 0) then
  begin
    Val := (Val xor $1F);
  end;
  if (BIT(Params, 3) <> 0) then
  begin
    if (BIT(Params, 0) <> 0) then
    begin
      Val := SwapBits(Val, [7, 6, 5, 3, 4, 1, 2, 0]);
    end
    else
    begin
      Val := SwapBits(Val, [7, 6, 5, 1, 2, 4, 3, 0]);
    end;
  end
  else
  begin
    if (BIT(Params, 0) <> 0) then
    begin
      Val := SwapBits(Val, [7, 6, 5, 2, 1, 3, 4, 0]);
    end;
  end;
  Exit(Val);
end;

function decrypt_type2b(Val, Params, SwapMode: Cardinal): Cardinal;
begin
  if (SwapMode = 0) then
  begin
    Val := SwapBits(Val, [1, 3, 4, 6, 5, 7, 0, 2]);
  end;
  if (SwapMode = 1) then
  begin
    Val := SwapBits(Val, [0, 1, 5, 4, 7, 3, 2, 6]);
  end;
  if (SwapMode = 2) then
  begin
    Val := SwapBits(Val, [3, 5, 4, 1, 6, 2, 0, 7]);
  end;
  if (SwapMode = 3) then
  begin
    Val := SwapBits(Val, [5, 2, 3, 0, 4, 7, 6, 1]);
  end;
  if ((BIT(Val, 7) <> 0) and (BIT(Val, 3) <> 0)) then
  begin
    Val := (Val xor $51);
  end;
  if (BIT(Val, 7) <> 0) then
  begin
    Val := (Val xor $4);
  end;
  if (BIT(Val, 5) <> 0) then
  begin
    Val := (Val xor $88);
  end;
  if (BIT(Val, 1) <> 0) then
  begin
    Val := (Val xor $20);
  end;
  if (BIT(Val, 4) <> 0) then
  begin
    Val := (Val xor $AA);
  end;
  if ((BIT(Val, 7) <> 0) and (BIT(Val, 5) <> 0)) then
  begin
    Val := (Val xor $11);
  end;
  if ((BIT(Val, 5) <> 0) and (BIT(Val, 1) <> 0)) then
  begin
    Val := (Val xor $11);
  end;
  if (BIT(Val, 6) <> 0) then
  begin
    Val := (Val xor $A0);
  end;
  if (BIT(Val, 3) <> 0) then
  begin
    Val := (Val xor $E2);
  end;
  if (BIT(Val, 2) <> 0) then
  begin
    Val := (Val xor $A);
  end;
  Val := (Val xor $8E);
  if (BIT(Params, 3) <> 0) then
  begin
    Val := (Val xor $4A);
  end;
  if (BIT(Params, 2) <> 0) then
  begin
    Val := (Val xor $EE);
  end;
  if (BIT(Params, 1) <> 0) then
  begin
    Val := (Val xor $80);
  end;
  if (BIT(Params, 0) <> 0) then
  begin
    Val := (Val xor $24);
  end;
  Exit(Val);
end;

function decrypt_type3a(Val, Params, SwapMode: Cardinal): Cardinal;
begin
  if (SwapMode = 0) then
  begin
    Val := SwapBits(Val, [5, 3, 1, 7, 0, 2, 6, 4]);
  end;
  if (SwapMode = 1) then
  begin
    Val := SwapBits(Val, [3, 1, 2, 5, 4, 7, 0, 6]);
  end;
  if (SwapMode = 2) then
  begin
    Val := SwapBits(Val, [5, 6, 1, 2, 7, 0, 4, 3]);
  end;
  if (SwapMode = 3) then
  begin
    Val := SwapBits(Val, [5, 6, 7, 0, 4, 2, 1, 3]);
  end;
  if (BIT(Val, 2) <> 0) then
  begin
    Val := (Val xor $B0);
  end;
  if (BIT(Val, 3) <> 0) then
  begin
    Val := (Val xor $1);
  end;
  if (BIT(Params, 0) <> 0) then
  begin
    Val := SwapBits(Val, [7, 2, 5, 4, 3, 1, 0, 6]);
  end;
  if (BIT(Val, 1) <> 0) then
  begin
    Val := (Val xor $41);
  end;
  if (BIT(Val, 3) <> 0) then
  begin
    Val := (Val xor $16);
  end;
  if (BIT(Params, 3) <> 0) then
  begin
    Val := (Val xor $18);
  end;
  if (BIT(Val, 3) <> 0) then
  begin
    Val := SwapBits(Val, [5, 6, 7, 4, 3, 2, 1, 0]);
  end;
  if (BIT(Val, 5) <> 0) then
  begin
    Val := (Val xor $6);
  end;
  Val := (Val xor $78);
  if (BIT(Params, 2) <> 0) then
  begin
    Val := (Val xor $80);
  end;
  if (BIT(Params, 1) <> 0) then
  begin
    Val := (Val xor $10);
  end;
  if (BIT(Params, 0) <> 0) then
  begin
    Val := (Val xor $1);
  end;
  Exit(Val);
end;

function decrypt_type3b(Val, Params, SwapMode: Cardinal): Cardinal;
begin
  if (SwapMode = 0) then
  begin
    Val := SwapBits(Val, [3, 7, 5, 4, 0, 6, 2, 1]);
  end;
  if (SwapMode = 1) then
  begin
    Val := SwapBits(Val, [7, 5, 4, 6, 1, 2, 0, 3]);
  end;
  if (SwapMode = 2) then
  begin
    Val := SwapBits(Val, [7, 4, 3, 0, 5, 1, 6, 2]);
  end;
  if (SwapMode = 3) then
  begin
    Val := SwapBits(Val, [2, 6, 4, 1, 3, 7, 0, 5]);
  end;
  if (BIT(Val, 2) <> 0) then
  begin
    Val := (Val xor $80);
  end;
  if (BIT(Val, 7) <> 0) then
  begin
    Val := SwapBits(Val, [7, 6, 3, 4, 5, 2, 1, 0]);
  end;
  if (BIT(Params, 3) <> 0) then
  begin
    Val := (Val xor $80);
  end;
  if (BIT(Val, 4) <> 0) then
  begin
    Val := (Val xor $40);
  end;
  if (BIT(Val, 1) <> 0) then
  begin
    Val := (Val xor $54);
  end;
  if ((BIT(Val, 7) <> 0) and (BIT(Val, 6) <> 0)) then
  begin
    Val := (Val xor $2);
  end;
  if (BIT(Val, 7) <> 0) then
  begin
    Val := (Val xor $2);
  end;
  if (BIT(Params, 3) <> 0) then
  begin
    Val := (Val xor $80);
  end;
  if (BIT(Params, 2) <> 0) then
  begin
    Val := (Val xor $1);
  end;
  if (BIT(Params, 3) <> 0) then
  begin
    Val := SwapBits(Val, [4, 6, 3, 2, 5, 0, 1, 7]);
  end;
  if (BIT(Val, 4) <> 0) then
  begin
    Val := (Val xor $2);
  end;
  if (BIT(Val, 5) <> 0) then
  begin
    Val := (Val xor $10);
  end;
  if (BIT(Val, 7) <> 0) then
  begin
    Val := (Val xor $4);
  end;
  Val := (Val xor $2C);
  if (BIT(Params, 1) <> 0) then
  begin
    Val := (Val xor $80);
  end;
  if (BIT(Params, 0) <> 0) then
  begin
    Val := (Val xor $8);
  end;
  Exit(Val);
end;

function decrypt_internal(Val, Key: Cardinal; Opcode: Boolean): Cardinal;
begin
  var Kind: Cardinal;
  Kind := 0;
  var SwapMode: Cardinal;
  SwapMode := 0;
  var Params: Cardinal;
  Params := 0;
  Key := (Key xor $ff);
  if (Key = $00) then
  begin
    Exit(Val);
  end;
  Kind := (Kind xor (BIT(Key, 0) shl 0));
  Kind := (Kind xor (BIT(Key, 2) shl 0));
  Kind := (Kind xor (BIT(Key, 0) shl 1));
  Kind := (Kind xor (BIT(Key, 1) shl 1));
  Kind := (Kind xor (BIT(Key, 2) shl 1));
  Kind := (Kind xor (BIT(Key, 4) shl 1));
  Kind := (Kind xor (BIT(Key, 4) shl 2));
  Kind := (Kind xor (BIT(Key, 5) shl 2));
  SwapMode := (SwapMode xor (BIT(Key, 0) shl 0));
  SwapMode := (SwapMode xor (BIT(Key, 1) shl 0));
  SwapMode := (SwapMode xor (BIT(Key, 2) shl 1));
  SwapMode := (SwapMode xor (BIT(Key, 3) shl 1));
  Params := (Params xor (BIT(Key, 0) shl 0));
  Params := (Params xor (BIT(Key, 0) shl 1));
  Params := (Params xor (BIT(Key, 2) shl 1));
  Params := (Params xor (BIT(Key, 3) shl 1));
  Params := (Params xor (BIT(Key, 0) shl 2));
  Params := (Params xor (BIT(Key, 1) shl 2));
  Params := (Params xor (BIT(Key, 6) shl 2));
  Params := (Params xor (BIT(Key, 1) shl 3));
  Params := (Params xor (BIT(Key, 6) shl 3));
  Params := (Params xor (BIT(Key, 7) shl 3));
  if (not Opcode) then
  begin
    Params := (Params xor $1);
    Kind := (Kind xor $1);
  end;
  Result := 0;
  case Kind of
    0:
      begin
        Exit(decrypt_type0(Val, Params, SwapMode));
      end;
    1:
      begin
        Exit(decrypt_type0(Val, Params, SwapMode));
      end;
    2:
      begin
        Exit(decrypt_type1a(Val, Params, SwapMode));
      end;
    3:
      begin
        Exit(decrypt_type1b(Val, Params, SwapMode));
      end;
    4:
      begin
        Exit(decrypt_type2a(Val, Params, SwapMode));
      end;
    5:
      begin
        Exit(decrypt_type2b(Val, Params, SwapMode));
      end;
    6:
      begin
        Exit(decrypt_type3a(Val, Params, SwapMode));
      end;
    7:
      begin
        Exit(decrypt_type3b(Val, Params, SwapMode));
      end;
  end;
end;

function MC8123(Address, Value: Cardinal; const MainKey: TBytes; Opcode: Boolean): Byte;
begin
  var Index := SwapBits(Address, [15, 14, 13, 12, 11, 10, 8, 6, 4, 2, 1, 0]);
  if not Opcode then
    Inc(Index, $1000);
  Result := Byte(decrypt_internal(Value, MainKey[Index], Opcode) and $FF);
end;

procedure InitializeMasks;
const
  Opcodes: array[0..386] of Word = (
    $013a, $033a, $053a, $073a, $083a, $093a, $0b3a, $0d3a, $0f3a, $103a, $10ba, $10fa, $113a, $117a, $11ba, $11fa, $123a, $12ba, $12fa, $133a, $137a, $13ba, $13fa, $143a, $14ba, $14fa, $153a, $157a,
    $15ba, $163a, $16ba, $16fa, $173a, $177a, $17ba, $183a, $18ba, $18fa, $193a, $197a, $19ba, $1a3a, $1aba, $1afa, $1b3a, $1b7a, $1bba, $1c3a, $1cba, $1cfa, $1d3a, $1d7a, $1dba, $1e3a, $1eba, $1efa,
    $1f3a, $1f7a, $1fba, $203a, $207a, $20ba, $20fa, $213a, $217a, $21ba, $21fa, $223a, $227a, $22ba, $22fa, $233a, $237a, $23ba, $23fa, $243a, $247a, $24ba, $24fa, $253a, $257a, $25ba, $263a, $267a,
    $26ba, $26fa, $273a, $277a, $27ba, $283a, $287a, $28ba, $28fa, $293a, $297a, $29ba, $2a3a, $2a7a, $2aba, $2afa, $2b3a, $2b7a, $2bba, $2c3a, $2c7a, $2cba, $2cfa, $2d3a, $2d7a, $2dba, $2e3a, $2e7a,
    $2eba, $2efa, $2f3a, $2f7a, $2fba, $303a, $307a, $30ba, $30fa, $313a, $317a, $31ba, $31fa, $323a, $327a, $32ba, $32fa, $333a, $337a, $33ba, $33fa, $343a, $347a, $34ba, $34fa, $353a, $357a, $35ba,
    $363a, $367a, $36ba, $36fa, $373a, $377a, $37ba, $383a, $387a, $38ba, $38fa, $393a, $397a, $39ba, $3a3a, $3a7a, $3aba, $3afa, $3b3a, $3b7a, $3bba, $3c3a, $3c7a, $3cba, $3cfa, $3d3a, $3d7a, $3dba,
    $3e3a, $3e7a, $3eba, $3efa, $3f3a, $3f7a, $3fba, $41ba, $43ba, $44fa, $45ba, $46fa, $47ba, $49ba, $4bba, $4cba, $4cfa, $4dba, $4fba, $803a, $807a, $80ba, $80fa, $81fa, $823a, $827a, $82ba, $82fa,
    $83fa, $843a, $847a, $84ba, $84fa, $85fa, $863a, $867a, $86ba, $86fa, $87fa, $883a, $887a, $88ba, $88fa, $89fa, $8a3a, $8a7a, $8aba, $8afa, $8bfa, $8c3a, $8c7a, $8cba, $8cfa, $8dfa, $8e3a, $8e7a,
    $8eba, $8efa, $8ffa, $903a, $907a, $90ba, $90fa, $91fa, $923a, $927a, $92ba, $92fa, $93fa, $943a, $947a, $94ba, $94fa, $95fa, $963a, $967a, $96ba, $96fa, $97fa, $983a, $987a, $98ba, $98fa, $99fa,
    $9a3a, $9a7a, $9aba, $9afa, $9bfa, $9c3a, $9c7a, $9cba, $9cfa, $9dfa, $9e3a, $9e7a, $9eba, $9efa, $9ffa, $b03a, $b07a, $b0ba, $b0fa, $b1fa, $b23a, $b27a, $b2ba, $b2fa, $b3fa, $b43a, $b47a, $b4ba,
    $b4fa, $b5fa, $b63a, $b67a, $b6ba, $b6fa, $b7fa, $b83a, $b87a, $b8ba, $b8fa, $b9fa, $ba3a, $ba7a, $baba, $bafa, $bbfa, $bc3a, $bc7a, $bcba, $bcfa, $bdfa, $be3a, $be7a, $beba, $befa, $bffa, $c03a,
    $c07a, $c0ba, $c0fa, $c1fa, $c23a, $c27a, $c2ba, $c2fa, $c3fa, $c43a, $c47a, $c4ba, $c4fa, $c5fa, $c63a, $c67a, $c6ba, $c6fa, $c7fa, $c83a, $c87a, $c8ba, $c8fa, $c9fa, $ca3a, $ca7a, $caba, $cafa,
    $cbfa, $cc3a, $cc7a, $ccba, $ccfa, $cdfa, $ce3a, $ce7a, $ceba, $cefa, $cffa, $d03a, $d07a, $d0ba, $d0fa, $d1fa, $d23a, $d27a, $d2ba, $d2fa, $d3fa, $d43a, $d47a, $d4ba, $d4fa, $d5fa, $d63a, $d67a,
    $d6ba, $d6fa, $d7fa, $d83a, $d87a, $d8ba, $d8fa, $d9fa, $da3a, $da7a, $daba, $dafa, $dbfa, $dc3a, $dc7a, $dcba, $dcfa, $ddfa, $de3a, $de7a, $deba, $defa, $dffa);
begin
  for var Opcode in Opcodes do
  begin
    Masked[0, Opcode shr 1] := True;
    Masked[1, Opcode shr 1] := True;
  end;
  for var Opcode := 0 to $7FFF do
  begin
    var V := Opcode * 2;
    if (V and $FF80 = $4E80) or (V and $F0F8 = $50C8) or (V and $F000 = $6000) then
      Masked[1, Opcode] := True;
  end;
end;

// Fixed 315-5177 / 317-5000 key. BSD-3-Clause reference: Nicola Salmoria,
// David Haywood (segacrp2_device.cpp); notice in REFERENCE-LICENSE.txt.
function Sega3155177(Address: Word; Value: Byte; Opcode: Boolean): Byte;
const
  Xors: array[0..127] of Byte = (
    $04, $54, $51, $15, $40, $44, $01, $51, $55, $10, $44, $41,
    $05, $55, $50, $14, $41, $45, $00, $50, $54, $11, $45, $40,
    $04, $54, $51, $15, $40, $44, $01, $51, $55, $10, $44, $41,
    $05, $55, $50, $14, $41, $45, $00, $50, $54, $11, $45, $40,
    $04, $54, $51, $15, $40, $44, $01, $51, $55, $10, $44, $41,
    $05, $55, $50, $14,

    $04, $54, $51, $15, $40, $44, $01, $51, $55, $10, $44, $41,
    $05, $55, $50, $14, $41, $45, $00, $50, $54, $11, $45, $40,
    $04, $54, $51, $15, $40, $44, $01, $51, $55, $10, $44, $41,
    $05, $55, $50, $14, $41, $45, $00, $50, $54, $11, $45, $40,
    $04, $54, $51, $15, $40, $44, $01, $51, $55, $10, $44, $41,
    $05, $55, $50, $14);
  Swaps: array[0..127] of Byte = (
    0, 0, 0, 0,
    1, 1, 1, 1, 1,
    2, 2, 2, 2, 2,
    3, 3, 3, 3,
    4, 4, 4, 4, 4,
    5, 5, 5, 5, 5,
    6, 6, 6, 6, 6,
    7, 7, 7, 7, 7,
    8, 8, 8, 8,
    9, 9, 9, 9, 9,
    10, 10, 10, 10, 10,
    11, 11, 11, 11, 11,
    12, 12, 12, 12, 12,
    13, 13,

    8, 8, 8, 8,
    9, 9, 9, 9, 9,
    10, 10, 10, 10, 10,
    11, 11, 11, 11,
    12, 12, 12, 12, 12,
    13, 13, 13, 13, 13,
    14, 14, 14, 14, 14,
    15, 15, 15, 15, 15,
    16, 16, 16, 16,
    17, 17, 17, 17, 17,
    18, 18, 18, 18, 18,
    19, 19, 19, 19, 19,
    20, 20, 20, 20, 20,
    21, 21);
  Permutations: array[0..23, 0..3] of Byte = (
    (6, 4, 2, 0), (4, 6, 2, 0), (2, 4, 6, 0), (0, 4, 2, 6),
    (6, 2, 4, 0), (6, 0, 2, 4), (6, 4, 0, 2), (2, 6, 4, 0),
    (4, 2, 6, 0), (4, 6, 0, 2), (6, 0, 4, 2), (0, 6, 4, 2),
    (4, 0, 6, 2), (0, 4, 6, 2), (6, 2, 0, 4), (2, 6, 0, 4),
    (0, 6, 2, 4), (2, 0, 6, 4), (0, 2, 6, 4), (4, 2, 0, 6),
    (2, 4, 0, 6), (4, 0, 2, 6), (2, 0, 4, 6), (0, 2, 4, 6));
begin
  var Row := SwapBits(Address, [14, 12, 9, 6, 3, 0]) * 2;
  if not Opcode then
    Inc(Row);
  var I := Swaps[Row];
  Result := Byte(SwapBits(Value, [7, Permutations[I, 0], 5, Permutations[I, 1],
        3, Permutations[I, 2], 1, Permutations[I, 3]]) xor Xors[Row]);
end;

initialization
  InitializeMasks;

end.

