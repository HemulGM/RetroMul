unit PS2.IOP.Loader;

// IOP module images (IRX): the .iopmod header (name, version, entry, gp,
// section sizes), loading the single loadable segment at a base address and
// applying its REL relocations (types 2/4/5/6 and the IRX v2 forms), and the
// import/export table formats loadcore links (magic 41E00000h/41C00000h,
// 8-character library name, stubs 'jr ra; addiu $0, $0, n').
// After Play! (BSD-2, IopBios::RelocateElf) and the ps2sdk loadcore format.
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

procedure LoadIRX(const Data: TBytes; const Info: TIRXInfo; RAM: PByte; Base: Cardinal);
begin
  Base := Base and PS2IOPRAMMask;
  FillChar((RAM + Base)^, Info.MemorySize, 0);
  if Info.FileSize > 0 then
    Move(Data[Info.FileOffset], (RAM + Base)^, Info.FileSize);
  var Size := Integer(Info.FileSize);
  var ShOff := U32(Data, 32);
  var ShSize := U16(Data, 46);
  var ShNum := U16(Data, 48);
  for var K := 0 to Integer(ShNum) - 1 do
  begin
    var S := Int64(ShOff) + Int64(K) * ShSize;
    if U32(Data, S + 4) <> 9 then
      Continue;
    var RelOff := Int64(U32(Data, S + 16));
    var Count := Integer(U32(Data, S + 20) div 8);
    var LastHi := -1;
    var HiWord: Cardinal := 0;
    var R := 0;
    while R < Count do
    begin
      var Rec := RelOff + Int64(R) * 8;
      var Offset := Integer(U32(Data, Rec));
      var RType := U32(Data, Rec + 4) and $FF;
      if (Offset >= 0) and (Offset + 4 <= Size) then
      begin
        var P := PCardinal(RAM + Base + Cardinal(Offset));
        var W := P^;
        case RType of
          2:
            P^ := Add32(W, Base);
          4:
            P^ := (W and $FC000000) or (Add32(W and $3FFFFFF, Base shr 2) and $3FFFFFF);
          5:
            if Info.Version2 then
            begin
              var NextOffset := Integer(U32(Data, Rec + 8));
              if (R + 1 < Count) and (NextOffset >= 0) and (NextOffset + 4 <= Size) then
              begin
                var NextW := PCardinal(RAM + Base + Cardinal(NextOffset))^;
                var V := Add32(Add32(SX16To32(NextW and $FFFF), W shl 16), Base);
                if (V and $8000) <> 0 then
                  V := Add32(V, $10000);
                P^ := (W and $FFFF0000) or (V shr 16);
              end;
            end
            else
            begin
              LastHi := Offset;
              HiWord := W;
            end;
          6:
            if Info.Version2 or (LastHi < 0) then
            begin
              var V := Add32(SX16To32(W and $FFFF), Base);
              P^ := (W and $FFFF0000) or (V and $FFFF);
            end
            else
            begin
              var V := Add32(Add32(SX16To32(W and $FFFF), HiWord shl 16), Base);
              P^ := (W and $FFFF0000) or (V and $FFFF);
              var HP := PCardinal(RAM + Base + Cardinal(LastHi));
              if (V and $8000) <> 0 then
                V := Add32(V, $10000);
              HP^ := (HP^ and $FFFF0000) or (V shr 16);
              LastHi := -1;
            end;
          250:
            // R_MIPSSCE_MHI16 with its addend record: a chain of HI16s.
            if R + 1 < Count then
            begin
              var V := Add32(U32(Data, Rec + 8), Base);
              if (V and $8000) <> 0 then
                V := Add32(V, $10000);
              V := V shr 16;
              var At := Offset;
              while (At >= 0) and (At + 4 <= Size) do
              begin
                var HP := PCardinal(RAM + Base + Cardinal(At));
                var Step := Integer(SmallInt(HP^ and $FFFF)) * 4;
                HP^ := (HP^ and $FFFF0000) or V;
                if Step = 0 then
                  Break;
                Inc(At, Step);
              end;
              Inc(R);
            end;
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
