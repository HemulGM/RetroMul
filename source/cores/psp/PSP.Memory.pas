unit PSP.Memory;

// Guest address space. Every segment (KUSEG, the uncached 0x40000000 mirror,
// KSEG0, KSEG1) folds to one physical map through `and $1FFFFFFF`; the map is a
// table of 4 KB pages pointing into host buffers. Stores into pages that hold
// decoded code notify the CPU.
{$IFDEF PSP_CHECKED}{$Q-}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types;

const
  PSPPageShift = 12;
  PSPPageSize = 1 shl PSPPageShift;
  PSPPageMask = PSPPageSize - 1;
  PSPPageCount = $20000000 shr PSPPageShift;
  // Page marks (CodeMarks): decoded code, and pages a device reads later.
  PSPPageCode = 1;
  PSPPageWatched = 2;

type
  TPSPCodeWrite = procedure(Address, Size: Cardinal) of object;

  TPSPVRAMFault = procedure of object;

  TPSPMemory = class
  private
    FRAM: TBytes;
    FVRAM: TBytes;
    FScratch: TBytes;
    FPages: array[0..PSPPageCount - 1] of PByte;
    FCodePages: array[0..PSPPageCount - 1] of Byte;
    FOnCodeWrite: TPSPCodeWrite;
    FFaultAddress: Cardinal;
    FFaults: Integer;
    FHeld: array[0..PSPVRAMSize div PSPPageSize - 1] of Boolean;
    FHeldCount: Integer;
    FOnVRAMFault: TPSPVRAMFault;
    FOnWatchFault: TPSPVRAMFault;
    FWatchAddress, FWatchSize: Cardinal;
    FVRAMShift: Integer;
    FWatched: TArray<Integer>;
    FWatchCount: Integer;
    function VRAMOffset(Address: Cardinal): Cardinal;
    function LinearPtr(Address, Size: Cardinal): PByte;
    procedure WatchRange(Address, Size: Cardinal);
    procedure WatchFault(Address, Size: Cardinal);
    function MirrorPtr(Address: Cardinal): PByte;
    procedure MapRange(Physical, Size: Cardinal; Base: PByte);
    function Unmapped(Address: Cardinal; Write: Boolean): Cardinal;
    procedure CodeWrite(Address, Size: Cardinal);
    function Fault(Address: Cardinal): PByte;
    procedure FaultRange(Address, Size: Cardinal);
  public
    constructor Create;
    procedure Reset;
    procedure SetVRAMTranslation(Width: Cardinal);
    function Read8(Address: Cardinal): Cardinal; inline;
    function Read16(Address: Cardinal): Cardinal; inline;
    function Read32(Address: Cardinal): Cardinal; inline;
    procedure Write8(Address, Value: Cardinal); inline;
    procedure Write16(Address, Value: Cardinal); inline;
    procedure Write32(Address, Value: Cardinal); inline;
    function ReadFloat(Address: Cardinal): Single; inline;
    procedure WriteFloat(Address: Cardinal; Value: Single); inline;
    // Host pointer for Size bytes starting at Address, or nil when the range
    // leaves its region.
    function Ptr(Address: Cardinal; Size: Cardinal = 1): PByte;
    // As Ptr for reading only: watched pages need not be given back first.
    function ReadPtr(Address: Cardinal; Size: Cardinal = 1): PByte;
    // As Ptr, without bringing back held VRAM pages: for readers that only
    // look after the device gave them back (the GE's CPU rasterizer).
    function HostPtr(Address: Cardinal; Size: Cardinal = 1): PByte;
    function Valid(Address: Cardinal; Size: Cardinal = 1): Boolean;
    function PageBase(Address: Cardinal): PByte; inline;
    procedure ReadBytes(Address: Cardinal; var Buffer; Size: Cardinal);
    procedure WriteBytes(Address: Cardinal; const Buffer; Size: Cardinal);
    procedure Fill(Address: Cardinal; Value: Byte; Size: Cardinal);
    // Tells the CPU that a range was written behind its back (DMA, disc reads).
    procedure Touched(Address, Size: Cardinal);
    procedure Copy(Dest, Source, Size: Cardinal);
    function ReadString(Address: Cardinal; MaxLength: Integer = 1024): string;
    function ReadAnsi(Address: Cardinal; MaxLength: Integer = 1024): RawByteString;
    procedure WriteString(Address: Cardinal; const Value: RawByteString; Capacity: Integer);
    // Pages holding decoded code: stores into them call OnCodeWrite.
    procedure MarkCode(Address: Cardinal); inline;
    procedure ClearCodeMarks;
    function IsCode(Address: Cardinal): Boolean; inline;
    // VRAM pages a device (the GE's GPU renderer) has newer data for: any
    // access to a held page, in any mirror, first calls OnVRAMFault, which
    // must bring the data back and release every page.
    procedure HoldVRAM(Page: Integer);
    procedure ReleaseVRAM;
    function VRAMHeld(Page: Integer): Boolean; inline;
    property HeldVRAMPages: Integer read FHeldCount;
    // Pages (of the whole map, by physical address) a device still reads:
    // any write to one, by the CPU, the HLE or DMA (stores, WriteN, Ptr),
    // first calls OnVRAMFault, which must finish reading and release them.
    procedure WatchPage(Page: Integer);
    procedure ReleaseWatches;
    property WatchedPages: Integer read FWatchCount;
    // The page table and the code marks themselves, for generated code that
    // reads them (PSP.CPU.JIT).
    function PageTable: PPointer; inline;
    function CodeMarks: PByte; inline;
    property OnCodeWrite: TPSPCodeWrite read FOnCodeWrite write FOnCodeWrite;
    property OnVRAMFault: TPSPVRAMFault read FOnVRAMFault write FOnVRAMFault;
    // When set, a write to a watched page calls it instead of OnVRAMFault: it
    // must finish reading the watched pages and release them (held pages may
    // stay held). WatchAddress and WatchSize are the write's.
    property OnWatchFault: TPSPVRAMFault read FOnWatchFault write FOnWatchFault;
    property WatchAddress: Cardinal read FWatchAddress;
    property WatchSize: Cardinal read FWatchSize;
    property RAM: TBytes read FRAM;
    property VRAM: TBytes read FVRAM;
    property Scratch: TBytes read FScratch;
    property FaultAddress: Cardinal read FFaultAddress;
    property Faults: Integer read FFaults;
    property VRAMShift: Integer read FVRAMShift;
  end;

// Depth's linear CPU view (mirror 3) to physical EDRAM bytes.
function PSPDepthOffset(I: Cardinal; Shift: Integer): Cardinal; inline;

implementation

function PSPDepthOffset(I: Cardinal; Shift: Integer): Cardinal;
begin
  if Shift = 0 then
  begin
    if (I and $600 = 0) or (I and $600 = $600) then
      I := I xor $600;
  end
  else
  begin
    var Mask := (Cardinal(1) shl Shift) - $20;
    var Bits := ((I and (Mask shr 1) and not Cardinal($3F)) shl 1) or (((not I) and $20) shl 1) or
      ((I shr (Shift - 6)) and $20);
    I := ((I xor (Cardinal(1) shl (Shift + 3))) and not Mask) or Bits;
  end;
  Result := I and (PSPVRAMSize - 1);
end;

constructor TPSPMemory.Create;
begin
  inherited Create;
  SetLength(FRAM, PSPRAMSize);
  SetLength(FVRAM, PSPVRAMSize);
  SetLength(FScratch, PSPScratchSize);
  MapRange(PSPRAMBase, PSPRAMSize, @FRAM[0]);
  // Even mirrors are linear. Odd mirrors also permute bytes within pages,
  // so their nil entries send the CPU/JIT through Read/Write instead.
  MapRange(PSPVRAMBase, PSPVRAMSize, @FVRAM[0]);
  MapRange(PSPVRAMBase + 2 * PSPVRAMSize, PSPVRAMSize, @FVRAM[0]);
  SetVRAMTranslation($400);
  MapRange(PSPScratchBase, PSPScratchSize, @FScratch[0]);
end;

procedure TPSPMemory.MapRange(Physical, Size: Cardinal; Base: PByte);
begin
  var Page := Physical shr PSPPageShift;
  for var I := 0 to Integer(Size shr PSPPageShift) - 1 do
    FPages[Page + Cardinal(I)] := Base + NativeUInt(I) * PSPPageSize;
end;

procedure TPSPMemory.Reset;
begin
  if (FHeldCount > 0) or (FWatchCount > 0) then
    FOnVRAMFault();
  FillChar(FRAM[0], Length(FRAM), 0);
  FillChar(FVRAM[0], Length(FVRAM), 0);
  FillChar(FScratch[0], Length(FScratch), 0);
  ClearCodeMarks;
  FFaults := 0;
  FFaultAddress := 0;
  SetVRAMTranslation($400);
end;

// Width is 0 (no depth permutation) or 512/1024/2048/4096 bytes.
procedure TPSPMemory.SetVRAMTranslation(Width: Cardinal);
begin
  var Shift := 0;
  while Width > 1 do
  begin
    Inc(Shift);
    Width := Width shr 1;
  end;
  if (Shift <> FVRAMShift) and (FHeldCount > 0) then
    FOnVRAMFault();
  FVRAMShift := Shift;
end;

// CPU view of mirrors 1 and 3, inverse of the bit permutations probed in
// gpu/ge/edramswizzle.cpp. The lowest five bits stay in place, so aligned
// halfword and word accesses are contiguous too.
function TPSPMemory.VRAMOffset(Address: Cardinal): Cardinal;
begin
  Result := Address and (PSPVRAMSize - 1);
  if (Address and $1FA00000) <> $04200000 then
    Exit;
  if (Address and $400000) <> 0 then
    Result := PSPDepthOffset(Result, FVRAMShift)
  else if FVRAMShift = 0 then
    Result := Result xor $600
  else
    Result := Result xor ((Cardinal(1) shl (FVRAMShift + 3)) or $40);
end;

function TPSPMemory.MirrorPtr(Address: Cardinal): PByte;
begin
  Result := nil;
  if (Address and $1FA00000) <> $04200000 then
    Exit;
  var I := VRAMOffset(Address);
  if FHeld[I shr PSPPageShift] then
    FOnVRAMFault();
  Result := @FVRAM[I];
end;

function TPSPMemory.Unmapped(Address: Cardinal; Write: Boolean): Cardinal;
begin
  Inc(FFaults);
  FFaultAddress := Address;
  Result := 0;
end;

procedure TPSPMemory.CodeWrite(Address, Size: Cardinal);
begin
  if Assigned(FOnCodeWrite) then
    FOnCodeWrite(Address and $1FFFFFFF, Size);
end;

function TPSPMemory.PageBase(Address: Cardinal): PByte;
begin
  Result := FPages[(Address and $1FFFFFFF) shr PSPPageShift];
  if Result = nil then
    Result := Fault(Address);
end;

// Synchronize the mapped physical page, then return a linear page base.
// Nonlinear views stay nil and scalar accesses resolve them through MirrorPtr.
function TPSPMemory.Fault(Address: Cardinal): PByte;
begin
  var Physical := Address and $1FFFFFFF;
  if (FHeldCount = 0) or (Physical < PSPVRAMBase) or (Physical >= PSPVRAMBase + 4 * PSPVRAMSize) or
    not FHeld[VRAMOffset(Physical) shr PSPPageShift] then
    Exit(nil);
  FOnVRAMFault();
  Result := FPages[Physical shr PSPPageShift];
end;

procedure TPSPMemory.FaultRange(Address, Size: Cardinal);
begin
  var Lo := Int64(Address and $1FFFFFFF);
  var Hi := Lo + Size;
  if Size = 0 then
    Hi := Lo + 1;
  if Lo < PSPVRAMBase then
    Lo := PSPVRAMBase;
  if Hi > PSPVRAMBase + 4 * PSPVRAMSize then
    Hi := PSPVRAMBase + 4 * PSPVRAMSize;
  // The supported permutations keep each guest 4 KB page in one physical
  // page, but the bank XOR can change which page that is.
  var Page := Lo shr PSPPageShift;
  while Page < (Hi + PSPPageMask) shr PSPPageShift do
  begin
    if FHeld[VRAMOffset(Cardinal(Page shl PSPPageShift)) shr PSPPageShift] then
    begin
      FOnVRAMFault();
      Exit;
    end;
    Inc(Page);
  end;
end;

procedure TPSPMemory.HoldVRAM(Page: Integer);
begin
  if FHeld[Page] then
    Exit;
  FHeld[Page] := True;
  Inc(FHeldCount);
  for var M := 0 to 1 do
    FPages[(PSPVRAMBase + Cardinal(M) * 2 * PSPVRAMSize) shr PSPPageShift + Cardinal(Page)] := nil;
end;

procedure TPSPMemory.ReleaseVRAM;
begin
  if FHeldCount = 0 then
    Exit;
  for var Page := 0 to High(FHeld) do
    if FHeld[Page] then
    begin
      FHeld[Page] := False;
      // Nonlinear mirrors must remain nil for both the CPU and generated code.
      for var M := 0 to 1 do
        FPages[(PSPVRAMBase + Cardinal(M) * 2 * PSPVRAMSize) shr PSPPageShift + Cardinal(Page)] :=
          @FVRAM[Page * PSPPageSize];
    end;
  FHeldCount := 0;
end;

function TPSPMemory.VRAMHeld(Page: Integer): Boolean;
begin
  Result := FHeld[Page];
end;

function TPSPMemory.Read8(Address: Cardinal): Cardinal;
begin
  var P := FPages[(Address and $1FFFFFFF) shr PSPPageShift];
  if P = nil then
  begin
    P := MirrorPtr(Address);
    if P <> nil then
      Exit(PByte(P)^);
    P := Fault(Address);
  end;
  if P <> nil then
    Result := P[Address and PSPPageMask]
  else
    Result := Unmapped(Address, False);
end;

function TPSPMemory.Read16(Address: Cardinal): Cardinal;
begin
  var P := FPages[(Address and $1FFFFFFF) shr PSPPageShift];
  if P = nil then
  begin
    P := MirrorPtr(Address);
    if P <> nil then
      Exit(PWord(P)^);
    P := Fault(Address);
  end;
  if P <> nil then
    Result := PWord(P + (Address and PSPPageMask))^
  else
    Result := Unmapped(Address, False);
end;

function TPSPMemory.Read32(Address: Cardinal): Cardinal;
begin
  var P := FPages[(Address and $1FFFFFFF) shr PSPPageShift];
  if P = nil then
  begin
    P := MirrorPtr(Address);
    if P <> nil then
      Exit(PCardinal(P)^);
    P := Fault(Address);
  end;
  if P <> nil then
    Result := PCardinal(P + (Address and PSPPageMask))^
  else
    Result := Unmapped(Address, False);
end;

procedure TPSPMemory.Write8(Address, Value: Cardinal);
begin
  var Page := (Address and $1FFFFFFF) shr PSPPageShift;
  if (FCodePages[Page] and PSPPageWatched) <> 0 then
    WatchFault(Address, 1);
  var P := FPages[Page];
  if P = nil then
  begin
    P := MirrorPtr(Address);
    if P <> nil then
    begin
      PByte(P)^ := Byte(Value);
      if (FCodePages[Page] and PSPPageCode) <> 0 then
        CodeWrite(Address, 1);
      Exit;
    end;
    P := Fault(Address);
  end;
  if P <> nil then
  begin
    P[Address and PSPPageMask] := Byte(Value);
    if (FCodePages[Page] and PSPPageCode) <> 0 then
      CodeWrite(Address, 1);
  end
  else
    Unmapped(Address, True);
end;

procedure TPSPMemory.Write16(Address, Value: Cardinal);
begin
  var Page := (Address and $1FFFFFFF) shr PSPPageShift;
  if (FCodePages[Page] and PSPPageWatched) <> 0 then
    WatchFault(Address, 2);
  var P := FPages[Page];
  if P = nil then
  begin
    P := MirrorPtr(Address);
    if P <> nil then
    begin
      PWord(P)^ := Word(Value);
      if (FCodePages[Page] and PSPPageCode) <> 0 then
        CodeWrite(Address, 2);
      Exit;
    end;
    P := Fault(Address);
  end;
  if P <> nil then
  begin
    PWord(P + (Address and PSPPageMask))^ := Word(Value);
    if (FCodePages[Page] and PSPPageCode) <> 0 then
      CodeWrite(Address, 2);
  end
  else
    Unmapped(Address, True);
end;

procedure TPSPMemory.Write32(Address, Value: Cardinal);
begin
  var Page := (Address and $1FFFFFFF) shr PSPPageShift;
  if (FCodePages[Page] and PSPPageWatched) <> 0 then
    WatchFault(Address, 4);
  var P := FPages[Page];
  if P = nil then
  begin
    P := MirrorPtr(Address);
    if P <> nil then
    begin
      PCardinal(P)^ := Value;
      if (FCodePages[Page] and PSPPageCode) <> 0 then
        CodeWrite(Address, 4);
      Exit;
    end;
    P := Fault(Address);
  end;
  if P <> nil then
  begin
    PCardinal(P + (Address and PSPPageMask))^ := Value;
    if (FCodePages[Page] and PSPPageCode) <> 0 then
      CodeWrite(Address, 4);
  end
  else
    Unmapped(Address, True);
end;

function TPSPMemory.ReadFloat(Address: Cardinal): Single;
begin
  var V := Read32(Address);
  Result := PSingle(@V)^;
end;

procedure TPSPMemory.WriteFloat(Address: Cardinal; Value: Single);
begin
  Write32(Address, PCardinal(@Value)^);
end;

procedure TPSPMemory.WatchRange(Address, Size: Cardinal);
begin
  if Size = 0 then
    Size := 1;
  var First := (Address and $1FFFFFFF) shr PSPPageShift;
  var Last := (UInt64(Address and $1FFFFFFF) + Size - 1) shr PSPPageShift;
  if Last >= PSPPageCount then
    Last := PSPPageCount - 1;
  for var Page := First to Cardinal(Last) do
    if (FCodePages[Page] and PSPPageWatched) <> 0 then
    begin
      WatchFault(Address, Size);
      Exit;
    end;
end;

procedure TPSPMemory.WatchFault(Address, Size: Cardinal);
begin
  FWatchAddress := Address;
  FWatchSize := Size;
  if Assigned(FOnWatchFault) then
    FOnWatchFault()
  else
    FOnVRAMFault();
end;

procedure TPSPMemory.WatchPage(Page: Integer);
begin
  if (FCodePages[Page] and PSPPageWatched) <> 0 then
    Exit;
  FCodePages[Page] := FCodePages[Page] or PSPPageWatched;
  if FWatchCount = Length(FWatched) then
    SetLength(FWatched, FWatchCount * 2 + 64);
  FWatched[FWatchCount] := Page;
  Inc(FWatchCount);
end;

procedure TPSPMemory.ReleaseWatches;
begin
  for var I := 0 to FWatchCount - 1 do
    FCodePages[FWatched[I]] := FCodePages[FWatched[I]] and not PSPPageWatched;
  FWatchCount := 0;
end;

function TPSPMemory.Ptr(Address: Cardinal; Size: Cardinal): PByte;
begin
  if FWatchCount > 0 then
    WatchRange(Address, Size);
  Result := ReadPtr(Address, Size);
end;

function TPSPMemory.ReadPtr(Address: Cardinal; Size: Cardinal): PByte;
begin
  if FHeldCount > 0 then
    FaultRange(Address, Size);
  Result := LinearPtr(Address, Size);
end;

function TPSPMemory.LinearPtr(Address: Cardinal; Size: Cardinal): PByte;
begin
  var Physical := Address and $1FFFFFFF;
  if Size = 0 then
    Size := 1;
  var Last := Physical + Size - 1;
  if (Last < Physical) or (Last > $1FFFFFFF) then
    Exit(nil);
  var P := FPages[Physical shr PSPPageShift];
  if P = nil then
    Exit(nil);
  // Regions are contiguous in host memory; verify the last page belongs to the
  // same buffer at the expected distance.
  var Q := FPages[Last shr PSPPageShift];
  if (Q = nil) or (NativeUInt(Q) - NativeUInt(P) <> NativeUInt((Last shr PSPPageShift) - (Physical shr PSPPageShift)) *
    PSPPageSize) then
    Exit(nil);
  Result := P + (Physical and PSPPageMask);
end;

function TPSPMemory.HostPtr(Address: Cardinal; Size: Cardinal): PByte;
begin
  var Physical := Address and $1FFFFFFF;
  if (Physical >= PSPVRAMBase) and (Physical < PSPVRAMBase + 4 * PSPVRAMSize) then
  begin
    if (Physical and $200000) <> 0 then
      Exit(nil);
    if Size = 0 then
      Size := 1;
    var Offset := (Physical - PSPVRAMBase) and (PSPVRAMSize - 1);
    if UInt64(Offset) + Size > PSPVRAMSize then
      Exit(nil);
    Exit(@FVRAM[Offset]);
  end;
  Result := LinearPtr(Address, Size);
end;

function TPSPMemory.Valid(Address, Size: Cardinal): Boolean;
begin
  var P := Address and $1FFFFFFF;
  if (P >= PSPVRAMBase) and (P < PSPVRAMBase + 4 * PSPVRAMSize) then
    Exit(UInt64(P) + Size <= PSPVRAMBase + 4 * PSPVRAMSize);
  Result := LinearPtr(Address, Size) <> nil;
end;

procedure TPSPMemory.ReadBytes(Address: Cardinal; var Buffer; Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var P := ReadPtr(Address, Size);
  if P <> nil then
    Move(P^, Buffer, Size)
  else
    for var I := 0 to Size - 1 do
      PByte(@Buffer)[I] := Read8(Address + I);
end;

procedure TPSPMemory.WriteBytes(Address: Cardinal; const Buffer; Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var P := Ptr(Address, Size);
  if P <> nil then
  begin
    Move(Buffer, P^, Size);
    var First := (Address and $1FFFFFFF) shr PSPPageShift;
    var Last := ((Address and $1FFFFFFF) + Size - 1) shr PSPPageShift;
    for var Page := First to Last do
      if (FCodePages[Page] and PSPPageCode) <> 0 then
      begin
        CodeWrite(Address, Size);
        Break;
      end;
  end
  else
    for var I := 0 to Size - 1 do
      Write8(Address + I, PByte(@Buffer)[I]);
end;

procedure TPSPMemory.Fill(Address: Cardinal; Value: Byte; Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var P := Ptr(Address, Size);
  if P <> nil then
  begin
    FillChar(P^, Size, Value);
    var First := (Address and $1FFFFFFF) shr PSPPageShift;
    var Last := ((Address and $1FFFFFFF) + Size - 1) shr PSPPageShift;
    for var Page := First to Last do
      if (FCodePages[Page] and PSPPageCode) <> 0 then
      begin
        CodeWrite(Address, Size);
        Break;
      end;
  end
  else
    for var I := 0 to Size - 1 do
      Write8(Address + I, Value);
end;

procedure TPSPMemory.Touched(Address, Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var First := (Address and $1FFFFFFF) shr PSPPageShift;
  var Last := ((Address and $1FFFFFFF) + Size - 1) shr PSPPageShift;
  if Last >= PSPPageCount then
    Last := PSPPageCount - 1;
  for var Page := First to Last do
    if (FCodePages[Page] and PSPPageCode) <> 0 then
    begin
      CodeWrite(Address, Size);
      Break;
    end;
end;

procedure TPSPMemory.Copy(Dest, Source, Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var D := Ptr(Dest, Size);
  var S := ReadPtr(Source, Size);
  if (S <> nil) and (D <> nil) then
  begin
    Move(S^, D^, Size);
    var First := (Dest and $1FFFFFFF) shr PSPPageShift;
    var Last := ((Dest and $1FFFFFFF) + Size - 1) shr PSPPageShift;
    for var Page := First to Last do
      if (FCodePages[Page] and PSPPageCode) <> 0 then
      begin
        CodeWrite(Dest, Size);
        Break;
      end;
  end
  else
    for var I := 0 to Size - 1 do
      Write8(Dest + I, Read8(Source + I));
end;

function TPSPMemory.ReadAnsi(Address: Cardinal; MaxLength: Integer): RawByteString;
begin
  Result := '';
  if Address = 0 then
    Exit;
  var N := 0;
  while (N < MaxLength) and (Read8(Address + Cardinal(N)) <> 0) do
    Inc(N);
  SetLength(Result, N);
  if N > 0 then
    ReadBytes(Address, Result[1], N);
end;

function TPSPMemory.ReadString(Address: Cardinal; MaxLength: Integer): string;
begin
  Result := string(ReadAnsi(Address, MaxLength));
end;

procedure TPSPMemory.WriteString(Address: Cardinal; const Value: RawByteString; Capacity: Integer);
begin
  if (Address = 0) or (Capacity <= 0) then
    Exit;
  var N := Length(Value);
  if N > Capacity - 1 then
    N := Capacity - 1;
  if N > 0 then
    WriteBytes(Address, Value[1], N);
  Write8(Address + Cardinal(N), 0);
end;

procedure TPSPMemory.MarkCode(Address: Cardinal);
begin
  var Page := (Address and $1FFFFFFF) shr PSPPageShift;
  FCodePages[Page] := FCodePages[Page] or PSPPageCode;
end;

procedure TPSPMemory.ClearCodeMarks;
begin
  if FWatchCount = 0 then
    FillChar(FCodePages, SizeOf(FCodePages), 0)
  else
    for var Page := 0 to High(FCodePages) do
      FCodePages[Page] := FCodePages[Page] and not PSPPageCode;
end;

function TPSPMemory.IsCode(Address: Cardinal): Boolean;
begin
  Result := (FCodePages[(Address and $1FFFFFFF) shr PSPPageShift] and PSPPageCode) <> 0;
end;

function TPSPMemory.PageTable: PPointer;
begin
  Result := @FPages[0];
end;

function TPSPMemory.CodeMarks: PByte;
begin
  Result := @FCodePages[0];
end;

end.

