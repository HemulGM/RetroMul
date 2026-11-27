unit RA.LibretroMemory;

interface

uses
  System.SysUtils, RA.Console;

{$SCOPEDENUMS ON}
{$A8}

type
  TRALibretroRAM = (SaveRAM = 0, SystemRAM = 2, VideoRAM = 3);

  TRALibretroMemoryBlock = record
    Data: PByte;
    Size: NativeUInt;
  end;

  PRALibretroMemoryBlock = ^TRALibretroMemoryBlock;

  TRALibretroMemoryDescriptor = record
    Data: PByte;
    Offset, Start, SelectMask, DisconnectMask, Size: NativeUInt;
  end;

  TRALibretroGetMemory = reference to function(Kind: TRALibretroRAM): TRALibretroMemoryBlock;

  // Layout of libretro's retro_memory_descriptor and retro_memory_map.
  PRALibretroMemoryMapEntry = ^TRALibretroMemoryMapEntry;

  TRALibretroMemoryMapEntry = record
    Flags: UInt64;
    Data: PByte;
    Offset, Start, SelectMask, DisconnectMask, Size: NativeUInt;
    AddressSpace: PAnsiChar;
  end;

  PRALibretroMemoryMap = ^TRALibretroMemoryMap;

  TRALibretroMemoryMap = record
    Descriptors: PRALibretroMemoryMapEntry;
    Count: Cardinal;
  end;

  TRALibretroGetCoreMemory = procedure(ID: Cardinal; Info: PRALibretroMemoryBlock); cdecl;

  TRALibretroMemoryMessage = procedure(MessageText: PAnsiChar); cdecl;

  // Layout of rc_libretro_memory_regions_t. The core owns the mapped RAM.
  PRALibretroMemory = ^TRALibretroMemory;

  TRALibretroMemory = record
  private
    FData: array[0..31] of PByte;
    FSizes: array[0..31] of NativeUInt;
    FTotalSize: NativeUInt;
    FCount: Integer;
    procedure AddBlock(Data: PByte; Size: NativeUInt; Kind: TRAMemoryRegionKind; const Description: string; const Log: TProc<string>);
    procedure MapDescriptors(const Regions: TArray<TRAMemoryRegion>; const Descriptors: array of TRALibretroMemoryDescriptor; const Log: TProc<string>);
    procedure MapRAM(const Regions: TArray<TRAMemoryRegion>; const GetMemory: TRALibretroGetMemory; const Log: TProc<string>);
  public
    function Initialize(ConsoleID: Cardinal; const Descriptors: array of TRALibretroMemoryDescriptor; const GetMemory: TRALibretroGetMemory; const Log: TProc<string> = nil): Boolean;
    function InitializeMemoryMap(ConsoleID: Cardinal; Map: PRALibretroMemoryMap; GetMemory: TRALibretroGetCoreMemory; const Log: TProc<string> = nil): Boolean;
    procedure Clear;
    function Find(Address: Cardinal): PByte; overload;
    function Find(Address: Cardinal; out Available: Cardinal): PByte; overload;
    function Read(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
    property Count: Integer read FCount;
    property TotalSize: NativeUInt read FTotalSize;
  end;

// Used when initialization has no per-call logger. Passing nil disables the callback.
procedure SetRALibretroMemoryVerboseCallback(Callback: TRALibretroMemoryMessage);

implementation

uses
  System.Math, System.SyncObjs;

var
  MemoryVerboseCallback: Pointer;

procedure SetRALibretroMemoryVerboseCallback(Callback: TRALibretroMemoryMessage);
begin
  TInterlocked.Exchange(MemoryVerboseCallback, @Callback);
end;

function RAMKind(Kind: TRAMemoryRegionKind): TRALibretroRAM;
begin
  case Kind of
    TRAMemoryRegionKind.SaveRAM:
      Result := TRALibretroRAM.SaveRAM;
    TRAMemoryRegionKind.VideoRAM:
      Result := TRALibretroRAM.VideoRAM;
  else
    Result := TRALibretroRAM.SystemRAM;
  end;
end;

function RAMName(Kind: TRAMemoryRegionKind): string;
begin
  case Kind of
    TRAMemoryRegionKind.SaveRAM:
      Result := 'SRAM';
    TRAMemoryRegionKind.VideoRAM:
      Result := 'VRAM';
    TRAMemoryRegionKind.Unused:
      Result := 'UNUSED';
  else
    Result := 'SYSTEM RAM';
  end;
end;

function CoreMemory(const GetMemory: TRALibretroGetMemory; Kind: TRALibretroRAM): TRALibretroMemoryBlock;
begin
  if Assigned(GetMemory) then
    Result := GetMemory(Kind)
  else
    Result := Default(TRALibretroMemoryBlock);
end;

function Address32(Value: UInt64): Cardinal;
begin
  Result := Cardinal(Value and High(Cardinal));
end;

function FindDescriptor(const Descriptors: array of TRALibretroMemoryDescriptor; Address: Cardinal; out Offset: NativeUInt): Integer;
var
  Descriptor: TRALibretroMemoryDescriptor;
  Reduced, Mask, BelowBit: Cardinal;
  I: Integer;
begin
  for I := 0 to High(Descriptors) do
  begin
    Descriptor := Descriptors[I];
    if Descriptor.SelectMask = 0 then
    begin
      if Address < Descriptor.Start then
        Continue;
      Offset := Address - Descriptor.Start;
    end
    else
    begin
      if ((Descriptor.Start xor Address) and Descriptor.SelectMask) <> 0 then
        Continue;
      Reduced := Address32(UInt64(Address) + (UInt64(1) shl 32) - Address32(Descriptor.Start));
      Mask := Address32(Descriptor.DisconnectMask);
      // Remove the disconnected address lines, shifting the higher bits down.
      while Mask <> 0 do
      begin
        BelowBit := (Mask - 1) and not Mask;
        Reduced := (Reduced and BelowBit) or ((Reduced shr 1) and not BelowBit);
        Mask := (Mask and (Mask - 1)) shr 1;
      end;
      Offset := Reduced;
    end;

    if Offset < Descriptor.Size then
      Exit(I);
  end;

  Offset := 0;
  Result := -1;
end;

procedure LogUnmapped(const Log: TProc<string>; const Region: TRAMemoryRegion; Address: Cardinal);
begin
  if Assigned(Log) and (Region.Kind <> TRAMemoryRegionKind.Unused) then
    Log(Format('Could not map region starting at $%.6x', [Address]));
end;

procedure TRALibretroMemory.Clear;
begin
  Self := Default(TRALibretroMemory);
end;

procedure TRALibretroMemory.AddBlock(Data: PByte; Size: NativeUInt; Kind: TRAMemoryRegionKind; const Description: string; const Log: TProc<string>);
var
  Index: Integer;
  Merge: Boolean;
begin
  if Size = 0 then
    Exit;
  if FCount = Length(FData) then
  begin
    if Assigned(Log) then
      Log('Too many memory memory regions to register');
    Exit;
  end;

  Index := FCount - 1;
  Merge := False;
  if Index >= 0 then
  begin
    if Data = nil then
      Merge := FData[Index] = nil
    else if FData[Index] <> nil then
      Merge := Data = FData[Index] + FSizes[Index];
  end;
  if not Merge then
  begin
    Index := FCount;
    FData[Index] := Data;
    FSizes[Index] := 0;
    Inc(FCount);
  end;
  Inc(FSizes[Index], Size);

  if Assigned(Log) then
    Log(Format('Registered 0x%.4x bytes of %s at $%.6x (%s)', [Size, RAMName(Kind), FTotalSize, Description]));
  Inc(FTotalSize, Size);
end;

procedure TRALibretroMemory.MapDescriptors(const Regions: TArray<TRAMemoryRegion>; const Descriptors: array of TRALibretroMemoryDescriptor; const Log: TProc<string>);
var
  Region: TRAMemoryRegion;
  Descriptor: TRALibretroMemoryDescriptor;
  Remaining, Offset, BlockSize: NativeUInt;
  Address, DisconnectSize, Mask: Cardinal;
  DescriptorIndex: Integer;
  Data: PByte;
  Description: string;
begin
  for Region in Regions do
  begin
    Remaining := Region.EndAddress - Region.StartAddress + 1;
    Address := Region.RealAddress;
    DisconnectSize := 0;
    while Remaining > 0 do
    begin
      DescriptorIndex := FindDescriptor(Descriptors, Address, Offset);
      if DescriptorIndex < 0 then
      begin
        LogUnmapped(Log, Region, Address32(UInt64(Address) + (UInt64(1) shl 32) -
            Region.RealAddress + Region.StartAddress));
        BlockSize := Remaining;
        if (DisconnectSize <> 0) and (Remaining > DisconnectSize) then
          BlockSize := DisconnectSize;
        AddBlock(nil, BlockSize, Region.Kind, 'null filler', Log);
        DisconnectSize := 0;
      end
      else
      begin
        Descriptor := Descriptors[DescriptorIndex];
        Data := Descriptor.Data;
        if Data <> nil then
          Inc(Data, Descriptor.Offset + Offset);

        BlockSize := Descriptor.Size - Offset;
        // Address reduction operates on the core's 32-bit emulated address.
        Mask := Address32(Descriptor.DisconnectMask);
        if (Mask <> 0) and (BlockSize > Descriptor.DisconnectMask) then
        begin
          DisconnectSize := Mask xor (Mask and (Mask - 1));
          BlockSize := DisconnectSize - (Address and (DisconnectSize - 1));
        end;
        BlockSize := Min(BlockSize, Remaining);
        if Assigned(Log) then
        begin
          Description := Format('descriptor %d, offset 0x%.6x', [DescriptorIndex + 1, Offset]);
          if Data = nil then
            Description := Description + ' [no pointer]';
        end;
        AddBlock(Data, BlockSize, Region.Kind, Description, Log);
      end;

      Dec(Remaining, BlockSize);
      Address := Address32(UInt64(Address) + BlockSize);
    end;
  end;
end;

procedure TRALibretroMemory.MapRAM(const Regions: TArray<TRAMemoryRegion>; const GetMemory: TRALibretroGetMemory; const Log: TProc<string>);
var
  Base: array[TRALibretroRAM] of Cardinal;
  Region: TRAMemoryRegion;
  Kind: TRALibretroRAM;
  Info: TRALibretroMemoryBlock;
  Size, Offset: NativeUInt;
  Description: string;
  HasPadding: Boolean;
begin
  FillChar(Base, SizeOf(Base), $FF);
  HasPadding := False;
  for Region in Regions do
  begin
    Size := Region.EndAddress - Region.StartAddress + 1;
    Kind := RAMKind(Region.Kind);
    if Base[Kind] = High(Cardinal) then
      Base[Kind] := Region.StartAddress;
    Offset := Region.StartAddress - Base[Kind];

    if (Region.Kind = TRAMemoryRegionKind.Unused) and (Size >= $10000) and
      (Regions[High(Regions)].EndAddress > $1000000) then
      HasPadding := True;
    if HasPadding then
    begin
      // Large gaps align disjoint memory banks. A flat RAM buffer cannot supply them.
      Info.Data := nil;
      Info.Size := Size;
    end
    else
      Info := CoreMemory(GetMemory, Kind);
    if Offset < Info.Size then
    begin
      Dec(Info.Size, Offset);
      if Info.Data <> nil then
      begin
        Inc(Info.Data, Offset);
        if Assigned(Log) then
          Description := Format('offset 0x%.6x', [Offset]);
      end
      else
        Description := 'null filler';
      Info.Size := Min(Info.Size, Size);
      AddBlock(Info.Data, Info.Size, Region.Kind, Description, Log);
    end
    else
    begin
      LogUnmapped(Log, Region, Region.StartAddress);
      Info.Size := 0;
    end;
    AddBlock(nil, Size - Info.Size, Region.Kind, 'null filler', Log);
  end;
end;

function TRALibretroMemory.Initialize(ConsoleID: Cardinal; const Descriptors: array of TRALibretroMemoryDescriptor; const GetMemory: TRALibretroGetMemory; const Log: TProc<string>): Boolean;
var
  Mapped: TRALibretroMemory;
  Regions: TArray<TRAMemoryRegion>;
  Info: TRALibretroMemoryBlock;
  Callback: TRALibretroMemoryMessage;
  EffectiveLog: TProc<string>;
  I: Integer;
begin
  EffectiveLog := Log;
  if not Assigned(EffectiveLog) then
  begin
    Callback := TRALibretroMemoryMessage(TInterlocked.CompareExchange(MemoryVerboseCallback, nil, nil));
    if Assigned(Callback) then
      EffectiveLog :=
        procedure(MessageText: string)
        var
          Encoded: UTF8String;
        begin
          Encoded := UTF8String(MessageText);
          Callback(PAnsiChar(Encoded));
        end;
  end;
  Mapped.Clear;
  Regions := RAConsoleMemoryRegions(ConsoleID);
  if Length(Regions) = 0 then
  begin
    Info := CoreMemory(GetMemory, TRALibretroRAM.SystemRAM);
    Mapped.AddBlock(Info.Data, Info.Size, TRAMemoryRegionKind.SystemRAM, 'offset 0x000000', EffectiveLog);
    Info := CoreMemory(GetMemory, TRALibretroRAM.SaveRAM);
    Mapped.AddBlock(Info.Data, Info.Size, TRAMemoryRegionKind.SaveRAM, 'offset 0x000000', EffectiveLog);
  end
  else if Length(Descriptors) > 0 then
    Mapped.MapDescriptors(Regions, Descriptors, EffectiveLog)
  else
    Mapped.MapRAM(Regions, GetMemory, EffectiveLog);

  Self := Mapped;
  for I := 0 to FCount - 1 do
    if FData[I] <> nil then
      Exit(True);
  Result := False;
end;

function TRALibretroMemory.InitializeMemoryMap(ConsoleID: Cardinal; Map: PRALibretroMemoryMap; GetMemory: TRALibretroGetCoreMemory; const Log: TProc<string>): Boolean;
var
  ReadRAM: TRALibretroGetMemory;
  Descriptors: TArray<TRALibretroMemoryDescriptor>;
  Entry: PRALibretroMemoryMapEntry;
begin
  if Assigned(GetMemory) then
    ReadRAM :=
      function(Kind: TRALibretroRAM): TRALibretroMemoryBlock
      begin
        Result := Default(TRALibretroMemoryBlock);
        GetMemory(Ord(Kind), @Result);
      end;

  if (Map <> nil) and (Map.Count <> 0) and (Length(RAConsoleMemoryRegions(ConsoleID)) <> 0) then
  begin
    if (Map.Descriptors = nil) or
      (UInt64(Map.Count) > UInt64(High(NativeInt)) div SizeOf(TRALibretroMemoryMapEntry)) then
      raise EArgumentException.Create('Invalid libretro memory map');
    SetLength(Descriptors, Map.Count);
    Entry := Map.Descriptors;
    for var Index := 0 to High(Descriptors) do
    begin
      Descriptors[Index].Data := Entry.Data;
      Descriptors[Index].Offset := Entry.Offset;
      Descriptors[Index].Start := Entry.Start;
      Descriptors[Index].SelectMask := Entry.SelectMask;
      Descriptors[Index].DisconnectMask := Entry.DisconnectMask;
      Descriptors[Index].Size := Entry.Size;
      Inc(Entry);
    end;
  end;
  Result := Initialize(ConsoleID, Descriptors, ReadRAM, Log);
end;

function TRALibretroMemory.Find(Address: Cardinal): PByte;
var
  Available: Cardinal;
begin
  Result := Find(Address, Available);
end;

function TRALibretroMemory.Find(Address: Cardinal; out Available: Cardinal): PByte;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    if Address >= FSizes[I] then
      Dec(Address, FSizes[I])
    else
    begin
      if FData[I] = nil then
        Break;
      Available := Cardinal(Min(UInt64(FSizes[I] - Address), UInt64(High(Cardinal))));
      Exit(FData[I] + Address);
    end;
  Available := 0;
  Result := nil;
end;

function TRALibretroMemory.Read(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
var
  I: Integer;
  Available: Cardinal;
begin
  Result := 0;
  if (Buffer = nil) or (Count = 0) then
    Exit;
  for I := 0 to FCount - 1 do
  begin
    if Address >= FSizes[I] then
    begin
      Dec(Address, FSizes[I]);
      Continue;
    end;
    if FData[I] = nil then
      Break;
    Available := Cardinal(Min(UInt64(Count), UInt64(FSizes[I] - Address)));
    Move((FData[I] + Address)^, Buffer^, Available);
    Inc(Result, Available);
    Dec(Count, Available);
    if Count = 0 then
      Break;
    Inc(Buffer, Available);
    Address := 0;
  end;
end;

end.

