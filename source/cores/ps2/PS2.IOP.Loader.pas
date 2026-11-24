unit PS2.IOP.Loader;

// IOP module images (IRX): the .iopmod header (name, version, entry, gp,
// section sizes), loading the single loadable segment at a base address and
// applying its REL relocations, and the import/export table formats loadcore
// links (magic 41E00000h/41C00000h, 8-character library name, stubs
// 'jr ra; addiu $0, $0, n').
// References: MIPS ELF relocation types; ps2sdk loadcore (AFL 2.0) for the
// .iopmod header and the IRX relocation rules (R_MIPSSCE_MHI16/ADDEND).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PS2.Types;

const
  IRXImportMagic = $41E00000;
  IRXExportMagic = $41C00000;
  IRXStubJrRa = $03E00008;

type
  TIRXInfo = record
    Name: string;
    Version: Word;
    Entry, GP: Cardinal;
    TextSize, DataSize, BssSize: Cardinal;
    // Bytes to reserve and to copy from the file.
    MemorySize, FileSize, FileOffset: Cardinal;
    Version2: Boolean;
  end;

// True for an IOP module (IRX v1/v2, or a plain MIPS ELF with .iopmod).
function ParseIRX(const Data: TBytes; out Info: TIRXInfo): Boolean;
// Copies the image to RAM + Base (IOP RAM, 2 MiB), clears bss, relocates.
procedure LoadIRX(const Data: TBytes; const Info: TIRXInfo; RAM: PByte; Base: Cardinal);
// The library name at an import/export table (8 bytes at +12).
function TableName(RAM: PByte; Table: Cardinal): string;

implementation

function U16(const D: TBytes; O: Int64): Word; inline;
begin
  if (O < 0) or (O + 2 > Length(D)) then
    Exit(0);
  Result := PWord(@D[O])^;
end;

function U32(const D: TBytes; O: Int64): Cardinal; inline;
begin
  if (O < 0) or (O + 4 > Length(D)) then
    Exit(0);
  Result := PCardinal(@D[O])^;
end;

function ParseIRX(const Data: TBytes; out Info: TIRXInfo): Boolean;
begin
  Info := Default(TIRXInfo);
  Result := False;
  if (Length(Data) < 52) or (U32(Data, 0) <> $464C457F) or (U16(Data, 18) <> 8) then
    Exit;
  var EType := U16(Data, 16);
  Info.Version2 := EType = $FF81;
  var PhOff := U32(Data, 28);
  var PhSize := U16(Data, 42);
  var PhNum := U16(Data, 44);
  var ShOff := U32(Data, 32);
  var ShSize := U16(Data, 46);
  var ShNum := U16(Data, 48);
  Info.Entry := U32(Data, 24);
  var ModOffset: Int64 := -1;
  var Loadable := False;
  for var K := 0 to Integer(PhNum) - 1 do
  begin
    var P := Int64(PhOff) + Int64(K) * PhSize;
    var PType := U32(Data, P);
    if PType = $70000080 then
      ModOffset := U32(Data, P + 4)
    else if (PType = 1) and not Loadable then
    begin
      Loadable := True;
      Info.FileOffset := U32(Data, P + 4);
      Info.FileSize := U32(Data, P + 16);
      Info.MemorySize := U32(Data, P + 20);
    end;
  end;
  if ModOffset < 0 then
    for var K := 0 to Integer(ShNum) - 1 do
    begin
      var S := Int64(ShOff) + Int64(K) * ShSize;
      if U32(Data, S + 4) = $70000080 then
        ModOffset := U32(Data, S + 16);
    end;
  if not Loadable or (ModOffset < 0) or (ModOffset + 26 > Length(Data)) then
    Exit;
  // .iopmod: module info, entry, gp, text, data, bss sizes, version, name.
  Info.Entry := U32(Data, ModOffset + 4);
  Info.GP := U32(Data, ModOffset + 8);
  Info.TextSize := U32(Data, ModOffset + 12);
  Info.DataSize := U32(Data, ModOffset + 16);
  Info.BssSize := U32(Data, ModOffset + 20);
  Info.Version := U16(Data, ModOffset + 24);
  var NameBytes: TBytes;
  var O := ModOffset + 26;
  while (O < Length(Data)) and (Data[O] <> 0) and (Length(NameBytes) < 64) do
  begin
    NameBytes := NameBytes + [Data[O]];
    Inc(O);
  end;
  Info.Name := TEncoding.ANSI.GetString(NameBytes);
  if Info.MemorySize < Info.TextSize + Info.DataSize + Info.BssSize then
    Info.MemorySize := Info.TextSize + Info.DataSize + Info.BssSize;
  if Int64(Info.FileOffset) + Info.FileSize > Length(Data) then
    Exit;
  Result := Info.MemorySize > 0;
end;

// The relocations (SHT_REL sections) of an image loaded at Base, as loadcore
// applies them: R_MIPS_16, R_MIPS_32, R_MIPS_26; R_MIPS_HI16 takes its low
// half from the instruction of the next record (its R_MIPS_LO16), which
// relocates on its own; R_MIPSSCE_MHI16 sets a chain of HI16 instructions
// (each one's immediate is the word distance to the next, 0 ends) from the
// address in the offset field of the following R_MIPSSCE_ADDEND record.
procedure LoadIRX(const Data: TBytes; const Info: TIRXInfo; RAM: PByte; Base: Cardinal);

  function At(Offset: Int64): PCardinal;
  begin
    if (Offset < 0) or (Offset + 4 > Info.MemorySize) then
      Exit(nil);
    Result := PCardinal(RAM + ((Base + Cardinal(Offset)) and PS2IOPRAMMask));
  end;

  // The high half of an address, rounded for a sign-extended low half.
  function High16(Address: Cardinal): Cardinal;
  begin
    Result := (((Address shr 15) + 1) shr 1) and $FFFF;
  end;

begin
  Base := Base and PS2IOPRAMMask;
  FillChar((RAM + Base)^, Info.MemorySize, 0);
  if Info.FileSize > 0 then
    Move(Data[Info.FileOffset], (RAM + Base)^, Info.FileSize);
  var ShOff := U32(Data, 32);
  var ShSize := U16(Data, 46);
  var ShNum := U16(Data, 48);
  for var K := 0 to Integer(ShNum) - 1 do
  begin
    var S := Int64(ShOff) + Int64(K) * ShSize;
    if U32(Data, S + 4) <> 9 then
      Continue;
    var RelOff := Int64(U32(Data, S + 16));
    var EntSize := Int64(U32(Data, S + 36));
    if EntSize = 0 then
      EntSize := 8;
    var Count := Integer(Int64(U32(Data, S + 20)) div EntSize);
    var R := 0;
    while R < Count do
    begin
      var Rec := RelOff + Int64(R) * EntSize;
      var Offset := Int64(U32(Data, Rec));
      var NextOffset := Int64(U32(Data, Rec + EntSize));
      var P := At(Offset);
      case U32(Data, Rec + 4) and $FF of
        1:
          if P <> nil then
            P^ := (P^ and $FFFF0000) or (Add32(Base, SX16To32(P^ and $FFFF)) and $FFFF);
        2:
          if P <> nil then
            P^ := Add32(P^, Base);
        4:
          if P <> nil then
          begin
            var Target := Add32(Base, (Cardinal(Offset) and $F0000000) or ((P^ and $3FFFFFF) shl 2));
            P^ := (P^ and $FC000000) or ((Target shr 2) and $3FFFFFF);
          end;
        5:
          begin
            var Low := At(NextOffset);
            if (P <> nil) and (Low <> nil) and (R + 1 < Count) then
              P^ := (P^ and $FFFF0000) or High16(Add32(Add32(Base, SX16To32(Low^ and $FFFF)), P^ shl 16));
          end;
        6:
          if P <> nil then
            P^ := (P^ and $FFFF0000) or (Add32(Base, P^) and $FFFF);
        250:
          if R + 1 < Count then
          begin
            var Value := High16(Add32(Base, Cardinal(NextOffset)));
            var Pos := Offset;
            for var Guard := 0 to $FFFF do
            begin
              var HP := At(Pos);
              if HP = nil then
                Break;
              var Step := Int64(SmallInt(HP^ and $FFFF)) * 4;
              HP^ := (HP^ and $FFFF0000) or Value;
              if Step = 0 then
                Break;
              Inc(Pos, Step);
            end;
            Inc(R);
          end;
      end;
      Inc(R);
    end;
  end;
end;

function TableName(RAM: PByte; Table: Cardinal): string;
begin
  var B: TBytes;
  for var K := 0 to 7 do
  begin
    var C := RAM[(Table + 12 + Cardinal(K)) and PS2IOPRAMMask];
    if C = 0 then
      Break;
    B := B + [C];
  end;
  Result := TEncoding.ANSI.GetString(B);
end;

end.
