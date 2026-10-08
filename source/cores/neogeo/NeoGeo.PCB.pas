unit NeoGeo.PCB;

interface

uses
  System.SysUtils, System.Classes;

procedure DecryptPCBGraphics(var Graphics: TBytes; KOF2003: Boolean);

procedure DecryptPCBFixed(const Graphics: TBytes; var Fixed: TBytes; KOF2003: Boolean);

procedure DecryptPCBBIOS(var BIOS: TBytes);

implementation

uses
  NeoGeo.Bootleg;

// MAME BSD-3-Clause, neopcb.cpp. Bryan McPhail, Ernesto Corvi,
// Andrew Prime, Zsolt Vasvari; scrambling research by Razoola and Halrin.
function Bits32(Value: Cardinal): Cardinal;
const
  Order: array[0..31] of Integer = (9, 13, 19, 0, 23, 15, 3, 5, 4, 12, 17, 30, 18, 21, 11, 6,
    27, 10, 26, 28, 20, 2, 14, 29, 24, 8, 1, 16, 25, 31, 7, 22);
begin
  Result := 0;
  for var Bit in Order do
    Result := (Result shl 1) or ((Value shr Bit) and 1);
end;

procedure DecryptPCBGraphics(var Graphics: TBytes; KOF2003: Boolean);
const
  XorBytes: array[0..3] of Byte = ($34, $21, $C4, $E9);
begin
  if (Length(Graphics) <> $4000000) and (Length(Graphics) <> $6000000) then
    raise EReadError.Create('Invalid Neo Geo PCB sprite region');
  var Buffer: TBytes;
  SetLength(Buffer, Length(Graphics));
  for var I := 0 to Length(Graphics) div 4 - 1 do
  begin
    var V: Cardinal := 0;
    for var B := 0 to 3 do
      V := V or (Cardinal(Graphics[I * 4 + B] xor XorBytes[B]) shl (B * 8));
    V := Bits32(V);
    for var B := 0 to 3 do
      Buffer[I * 4 + B] := Byte((V shr (B * 8)) and $FF);
  end;
  for var I := 0 to Length(Graphics) div 4 - 1 do
  begin
    var Target := I * 4;
    var Source := Target;
    if KOF2003 then
      Target := (Target and $7F800000) + BootlegBits(Target and $7FFFFF,
        [23, 21, 10, 20, 19, 22, 18, 17, 16, 15, 14, 13, 12, 11, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0])
    else
      Source := ((I and $7FE00000) + (BootlegBits(I and $1FFFFF,
        [23, 22, 21, 4, 11, 14, 8, 12, 16, 0, 10, 19, 3, 6, 2, 7, 13, 1, 17, 9, 20, 15, 18, 5]) xor $C8923)) * 4;
    if (Int64(Source) + 4 > Length(Buffer)) or (Int64(Target) + 4 > Length(Graphics)) then
      raise EReadError.Create('Invalid Neo Geo PCB sprite wiring');
    for var B := 0 to 3 do
      Graphics[Target + B] := Buffer[Source + B];
  end;
end;

procedure DecryptPCBFixed(const Graphics: TBytes; var Fixed: TBytes; KOF2003: Boolean);
begin
  if KOF2003 then
  begin
    if (Length(Fixed) <> $100000) or (Length(Graphics) < $1080000) then
      raise EReadError.Create('Invalid KOF2003 PCB fixed region');
    for var I := 0 to $7FFFF do
    begin
      var A := (I and $7FFFFFE0) + ((I and 7) shl 2) + (((not I) and 8) shr 2) + ((I and $10) shr 4);
      Fixed[I] := Graphics[Length(Graphics) - $1080000 + A];
      Fixed[$80000 + I] := Graphics[Length(Graphics) - $80000 + A];
    end;
  end;
  for var I := 0 to High(Fixed) do
    Fixed[I] := Byte(BootlegBits(Fixed[I] xor $D2, [4, 0, 7, 2, 5, 1, 6, 3]));
end;

procedure DecryptPCBBIOS(var BIOS: TBytes);
const
  AddressXor: array[0..63] of Integer = ($04, $0A, $04, $0A, $04, $0A, $04, $0A,
    $0A, $04, $0A, $04, $0A, $04, $0A, $04, $09, $07, $09, $07, $09, $07, $09, $07,
    $09, $09, $04, $04, $09, $09, $04, $04, $0B, $0D, $0B, $0D, $03, $05, $03, $05,
    $0E, $0E, $03, $03, $0E, $0E, $03, $03, $03, $05, $0B, $0D, $03, $05, $0B, $0D,
    $04, $00, $04, $00, $0E, $0A, $0E, $0A);
begin
  if Length(BIOS) <> $80000 then
    raise EReadError.Create('Invalid KOF2003 PCB BIOS size');
  var Buffer := Copy(BIOS);
  for var I := 0 to $3FFFF do
  begin
    var A := I xor $20;
    if (I and $20) <> 0 then
      A := A xor $10;
    if (I and $10) = 0 then
      A := A xor $40;
    if (I and 4) = 0 then
      A := A xor $80;
    if (I and $200) <> 0 then
      A := A xor $100;
    if (I and $2000) = 0 then
      A := A xor $400;
    if (I and $10000) = 0 then
      A := A xor $1000;
    if (I and $2000) <> 0 then
      A := A xor $8000;
    A := A xor AddressXor[((I shr 1) and $38) or (I and 7)];
    var W := Integer(Buffer[A * 2]) * 256 + Buffer[A * 2 + 1];
    if (W and 4) <> 0 then
      W := W xor 1;
    if (W and $10) <> 0 then
      W := W xor 2;
    if (W and $20) <> 0 then
      W := W xor 8;
    BIOS[I * 2] := Byte(W shr 8);
    BIOS[I * 2 + 1] := Byte(W and $FF);
  end;
end;

end.

