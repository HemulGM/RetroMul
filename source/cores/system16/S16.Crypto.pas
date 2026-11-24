unit S16.Crypto;

interface

uses
  System.SysUtils;

function FD1089(Address, Value: Cardinal; const MainKey: TBytes; Opcode, VariantB: Boolean): Word;

function FD1094(Address, Val: Cardinal; const MainKey: TBytes; State: Byte; Vector_Fetch: Boolean): Word;

function MC8123(Address, Value: Cardinal; const MainKey: TBytes; Opcode: Boolean): Byte;

function Sega3155177(Address: Word; Value: Byte; Opcode: Boolean): Byte;

implementation

uses
  HW.SegaCrypto;

function FD1089(Address, Value: Cardinal; const MainKey: TBytes; Opcode, VariantB: Boolean): Word;
begin
  Result := HW.SegaCrypto.FD1089(Address, Value, MainKey, Opcode, VariantB);
end;

function FD1094(Address, Val: Cardinal; const MainKey: TBytes; State: Byte; Vector_Fetch: Boolean): Word;
begin
  Result := HW.SegaCrypto.FD1094(Address, Val, MainKey, State, Vector_Fetch);
end;

function MC8123(Address, Value: Cardinal; const MainKey: TBytes; Opcode: Boolean): Byte;
begin
  Result := HW.SegaCrypto.MC8123(Address, Value, MainKey, Opcode);
end;

function Sega3155177(Address: Word; Value: Byte; Opcode: Boolean): Byte;
begin
  Result := HW.SegaCrypto.Sega3155177(Address, Value, Opcode);
end;

end.
