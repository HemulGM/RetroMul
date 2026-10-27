unit PSP.Executable;

interface

uses
  System.SysUtils, PSP.Memory, PSP.Media;

type
  TPSPImport = record
    ModuleName: string;
    NID, Address: Cardinal;
  end;

  TPSPExport = record
    ModuleName: string;
    NID, Address: Cardinal;
    Variable: Boolean;
  end;

  TPSPExecutable = record
    Entry, GP, LowAddress, HighAddress, Attributes: Cardinal;
    ModuleName: string;
    Imports: TArray<TPSPImport>;
    Symbols: TArray<TPSPExport>;
    class function Load(const Data: TBytes; Memory: TPSPMemory; LoadAddress: Cardinal = PSPUserBase + $4000): TPSPExecutable; static;
  end;

implementation

uses
  System.Generics.Collections, PSP.Relocations;

class function TPSPExecutable.Load(const Data: TBytes; Memory: TPSPMemory; LoadAddress: Cardinal): TPSPExecutable;
begin
  Result := Default(TPSPExecutable);
  if (Length(Data) < 52) or (PSPLE32(Data, 0) <> $464C457F) or
    (Data[4] <> 1) or (Data[5] <> 1) or (Data[6] <> 1) or
    (PSPLE16(Data, 18) <> 8) or (PSPLE32(Data, 20) <> 1) or (PSPLE16(Data, 40) <> 52) then
    raise EPSPFormat.Create('PSP: expected little-endian MIPS ELF32');
  var Kind := PSPLE16(Data, 16);
  if (Kind <> 2) and (Kind <> $FFA0) then
    raise EPSPFormat.Create('PSP: unsupported ELF type');
  var Base: Cardinal := 0;
  if Kind = $FFA0 then
    Base := LoadAddress;
  var PHOffset := Int64(PSPLE32(Data, 28));
  var PHSize := PSPLE16(Data, 42);
  var PHCount := PSPLE16(Data, 44);
  if (PHSize <> 32) or (PHCount = 0) or (PHCount > 128) or
    (PHOffset < 52) or (PHOffset + Int64(PHCount) * PHSize > Length(Data)) then
    raise EPSPFormat.Create('PSP: invalid ELF program header table');
  var Segments: TArray<TPSPLoadSegment>;
  SetLength(Segments, PHCount);
  Result.LowAddress := High(Cardinal);
  var NoEntry := PSPLE32(Data, 24) = $FFFFFFFF;
  if not NoEntry and (UInt64(Base) + PSPLE32(Data, 24) > High(Cardinal)) then
    raise EPSPFormat.Create('PSP: invalid relocated entry');
  if not NoEntry then
    Result.Entry := Base + PSPLE32(Data, 24);
  var EntryMapped := False;
  for var I := 0 to PHCount - 1 do
  begin
    var P := PHOffset + Int64(I) * PHSize;
    if PSPLE32(Data, P) <> 1 then
      Continue;
    var Segment: TPSPLoadSegment;
    Segment.Loaded := True;
    Segment.Offset := PSPLE32(Data, P + 4);
    if UInt64(Base) + PSPLE32(Data, P + 8) > High(Cardinal) then
      raise EPSPFormat.Create('PSP: invalid relocated segment');
    Segment.Address := Base + PSPLE32(Data, P + 8);
    Segment.FileSize := PSPLE32(Data, P + 16);
    Segment.MemorySize := PSPLE32(Data, P + 20);
    var Finish := UInt64(Segment.Address) + Segment.MemorySize;
    if (Segment.FileSize > Segment.MemorySize) or
      (Int64(Segment.Offset) + Segment.FileSize > Length(Data)) or
      (Segment.Address < PSPRAMBase + $2000) or ((Kind = 2) and (Segment.Address < PSPUserBase)) or (Finish > PSPRAMBase + PSPRAMSize) then
      raise EPSPFormat.Create('PSP: invalid ELF load segment');
    var Alignment := PSPLE32(Data, P + 28);
    // PSP PRX segments need not have matching file/virtual alignment residues.
    if (Alignment > 1) and ((Alignment and (Alignment - 1)) <> 0) then
      raise EPSPFormat.Create('PSP: invalid ELF segment alignment');
    if (PSPLE32(Data, P + 24) and 1 <> 0) and
      (Result.Entry >= Segment.Address) and (UInt64(Result.Entry) + 4 <= UInt64(Segment.Address) + Segment.FileSize) then
      EntryMapped := True;
    for var Previous in Segments do
      if Previous.Loaded and (Segment.MemorySize <> 0) and (Previous.MemorySize <> 0) and
        (UInt64(Segment.Address) < UInt64(Previous.Address) + Previous.MemorySize) and
        (UInt64(Previous.Address) < Finish) then
        raise EPSPFormat.Create('PSP: overlapping ELF segments');
    Segments[I] := Segment;
    if Segment.Address < Result.LowAddress then
      Result.LowAddress := Segment.Address;
    if Finish > Result.HighAddress then
      Result.HighAddress := Finish;
  end;
  if not NoEntry and (not EntryMapped or (Result.Entry and 3 <> 0)) then
    raise EPSPFormat.Create('PSP: ELF entry is outside executable file data');
  // Validate all segment ranges before modifying guest memory.
  for var Segment in Segments do
  begin
    if not Segment.Loaded then
      Continue;
    Memory.Zero(Segment.Address, Segment.MemorySize);
    Memory.Load(Segment.Address, Copy(Data, Segment.Offset, Segment.FileSize));
  end;
  var SHOffset := Int64(PSPLE32(Data, 32));
  var SHSize := PSPLE16(Data, 46);
  var SHCount := PSPLE16(Data, 48);
  var SHNames := PSPLE16(Data, 50);
  if (SHCount <> 0) and ((SHSize <> 40) or (SHNames >= SHCount) or (SHOffset < 52) or
    (SHOffset + Int64(SHCount) * SHSize > Length(Data))) then
    raise EPSPFormat.Create('PSP: invalid ELF section table');
  var HadRelocations := False;
  if Kind = $FFA0 then
  begin
    for var I := 0 to Integer(SHCount) - 1 do
    begin
      var S := SHOffset + Int64(I) * SHSize;
      if PSPLE32(Data, S + 4) = $700000A0 then
      begin
        RelocatePSPRecords(Data, PSPLE32(Data, S + 16), PSPLE32(Data, S + 20), Memory, Segments);
        HadRelocations := True;
      end;
    end;
    if not HadRelocations then
      for var I := 0 to PHCount - 1 do
      begin
        var P := PHOffset + Int64(I) * PHSize;
        if PSPLE32(Data, P) = $700000A0 then
          RelocatePSPRecords(Data, PSPLE32(Data, P + 4), PSPLE32(Data, P + 16), Memory, Segments);
        if PSPLE32(Data, P) = $700000A1 then
          RelocatePSPCompressed(Data, PSPLE32(Data, P + 4), PSPLE32(Data, P + 16), I, Memory, Segments);
      end;
  end;
  var ModuleOffset: Int64 := -1;
  if SHCount <> 0 then
  begin
    var NamesHeader := SHOffset + Int64(SHNames) * SHSize;
    var NamesOffset := Int64(PSPLE32(Data, NamesHeader + 16));
    var NamesSize := Int64(PSPLE32(Data, NamesHeader + 20));
    if NamesOffset + NamesSize > Length(Data) then
      raise EPSPFormat.Create('PSP: invalid ELF names');
    for var I := 0 to SHCount - 1 do
    begin
      var S := SHOffset + Int64(I) * SHSize;
      var NameIndex := Int64(PSPLE32(Data, S));
      if NameIndex >= NamesSize then
        raise EPSPFormat.Create('PSP: invalid ELF section name');
      var NameEnd := NamesOffset + NameIndex;
      while (NameEnd < NamesOffset + NamesSize) and (Data[NameEnd] <> 0) do
        Inc(NameEnd);
      if NameEnd = NamesOffset + NamesSize then
        raise EPSPFormat.Create('PSP: unterminated ELF section name');
      var Name := TEncoding.ASCII.GetString(Data, NamesOffset + NameIndex, NameEnd - NamesOffset - NameIndex);
      if (Name <> '.rodata.sceModuleInfo') and (Name <> '.sceModuleInfo') then
        Continue;
      var Offset := Int64(PSPLE32(Data, S + 16));
      if (PSPLE32(Data, S + 20) < 52) or (Offset + 52 > Length(Data)) then
        raise EPSPFormat.Create('PSP: truncated module info');
      ModuleOffset := Offset;
      Break;
    end;
  end;
  if (ModuleOffset < 0) and (Kind = $FFA0) then
    ModuleOffset := PSPLE32(Data, PHOffset + 12) and $7FFFFFFF;
  if ModuleOffset < 0 then
    Exit;
  var ModuleAddress: Cardinal := 0;
  for var Segment in Segments do
    if Segment.Loaded and (ModuleOffset >= Segment.Offset) and
      (ModuleOffset + 52 <= Int64(Segment.Offset) + Segment.FileSize) then
      ModuleAddress := Segment.Address + Cardinal(ModuleOffset - Segment.Offset);
  if ModuleAddress = 0 then
    raise EPSPFormat.Create('PSP: module info outside loaded segments');
  Result.ModuleName := Memory.ReadString(ModuleAddress + 4, 28);
  Result.Attributes := Memory.Read16(ModuleAddress);
  Result.GP := Memory.Read32(ModuleAddress + 32);
  var Symbols := TList<TPSPExport>.Create;
  try
    var Table := Memory.Read32(ModuleAddress + 36);
    var TableEnd := Memory.Read32(ModuleAddress + 40);
    if (TableEnd < Table) or ((TableEnd <> Table) and not Memory.IsValid(Table, TableEnd - Table)) then
      raise EPSPFormat.Create('PSP: invalid export table');
    while Table < TableEnd do
    begin
      if TableEnd - Table < 16 then
        raise EPSPFormat.Create('PSP: truncated export descriptor');
      var Size := Cardinal(Memory.Read8(Table + 8)) * 4;
      if (Size < 16) or (Size > TableEnd - Table) then
        raise EPSPFormat.Create('PSP: invalid export descriptor size');
      var Functions := Cardinal(Memory.Read16(Table + 10));
      var Variables := Cardinal(Memory.Read8(Table + 9));
      if (Size >= 20) and (Memory.Read16(Table + 16) <> 0) then
        Variables := Memory.Read16(Table + 16);
      var Count := Functions + Variables;
      var resident := Memory.Read32(Table + 12);
      if not Memory.IsValid(resident, Count * 8) then
        raise EPSPFormat.Create('PSP: invalid resident export arrays');
      var Name := '';
      if Memory.Read32(Table) <> 0 then
        Name := Memory.ReadString(Memory.Read32(Table), 256);
      for var J := 0 to Integer(Count) - 1 do
      begin
        var Item: TPSPExport;
        Item.ModuleName := Name;
        Item.NID := Memory.Read32(resident + Cardinal(J) * 4);
        Item.Address := Memory.Read32(resident + (Count + Cardinal(J)) * 4);
        Item.Variable := Cardinal(J) >= Functions;
        if not Memory.IsValid(Item.Address, 1) or (not Item.Variable and (Item.Address and 3 <> 0)) then
          raise EPSPFormat.Create('PSP: export address outside guest memory');
        Symbols.Add(Item);
      end;
      Inc(Table, Size);
    end;
    Result.Symbols := Symbols.ToArray;
  finally
    Symbols.Free;
  end;
  var Imports := TList<TPSPImport>.Create;
  try
    var Stub := Memory.Read32(ModuleAddress + 44);
    var StubEnd := Memory.Read32(ModuleAddress + 48);
    if (StubEnd < Stub) or ((StubEnd <> Stub) and not Memory.IsValid(Stub, StubEnd - Stub)) then
      raise EPSPFormat.Create('PSP: invalid import table');
    while Stub < StubEnd do
    begin
      if StubEnd - Stub < 20 then
        raise EPSPFormat.Create('PSP: truncated import descriptor');
      var Size := Cardinal(Memory.Read8(Stub + 8)) * 4;
      var Functions := Cardinal(Memory.Read16(Stub + 10));
      if (Size < 20) or (Size > StubEnd - Stub) then
        raise EPSPFormat.Create('PSP: invalid import descriptor size');
      if Memory.Read8(Stub + 9) <> 0 then
        raise EPSPFormat.Create('PSP: variable imports are not implemented');
      var ModuleName := Memory.ReadString(Memory.Read32(Stub), 256);
      var NIDs := Memory.Read32(Stub + 12);
      var Stubs := Memory.Read32(Stub + 16);
      if (Functions > 0) and (not Memory.IsValid(NIDs, Functions * 4) or not Memory.IsValid(Stubs, Functions * 8)) then
        raise EPSPFormat.Create('PSP: import arrays outside guest memory');
      for var J := 0 to Integer(Functions) - 1 do
      begin
        var Item: TPSPImport;
        Item.ModuleName := ModuleName;
        Item.NID := Memory.Read32(NIDs + Cardinal(J) * 4);
        Item.Address := Stubs + Cardinal(J) * 8;
        Imports.Add(Item);
      end;
      Inc(Stub, Size);
    end;
    Result.Imports := Imports.ToArray;
  finally
    Imports.Free;
  end;
end;

end.

