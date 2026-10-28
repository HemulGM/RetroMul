unit DC.Memory;

// Dreamcast memories and the SH-4 physical page tables. VRAM is stored in
// its 32-bit (linear) arrangement; the 64-bit bus interleaves the two 4 MiB
// banks every 32 bits. Write generations count stores per 4 KiB page so that
// decoded SH-4 code and cached textures can detect modification.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, Core.Snapshots, HW.SH4, DC.Types;

type
  TDCVRAMBarrier = procedure of object;

  TDCMemory = class
  private
    FBlocks: array[0..4] of Pointer;
    function Allocate(Index, Size: Integer): PByte;
  public
    RAM, VRAM, ARAM, Boot, Flash: PByte;
    RAMGens: array[0..DCRAMSize div 4096 - 1] of Cardinal;
    VRAMGens: array[0..DCVRAMSize div 4096 - 1] of Cardinal;
    ReadPages, WritePages: TSH4PhysicalPages;
    Gens: TSH4PhysicalGens;
    // A render in flight writes linear VRAM PendingFirst..PendingLast-1;
    // device accesses that may observe that range call Barrier first.
    PendingFirst, PendingLast: Cardinal;
    Barrier: TDCVRAMBarrier;
    constructor Create;
    destructor Destroy; override;
    procedure BuildPages;
    procedure Observe(Offset, Size: Cardinal); inline;
    // Direct CPU pages of the 32-bit VRAM view over linear First..Last-1:
    // removed so accesses take the device path, or restored.
    procedure MapVRAMPages(First, Last: Cardinal; Direct: Boolean);
    // Offset in the 64-bit VRAM view to the linear (32-bit view) offset.
    class function VRAM64(Offset: Cardinal): Cardinal; static; inline;
    procedure TouchVRAM(Offset, Size: Cardinal); inline;
    procedure TouchRAM(Offset, Size: Cardinal);
    function VRAMRead32(Offset: Cardinal): Cardinal; inline;
    procedure VRAMWrite32(Offset, Value: Cardinal); inline;
    function VRAMRead64Path(Offset: Cardinal; Size: Integer): UInt64;
    procedure VRAMWrite64Path(Offset: Cardinal; Value: UInt64; Size: Integer);
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

constructor TDCMemory.Create;
begin
  inherited Create;
  RAM := Allocate(0, DCRAMSize);
  VRAM := Allocate(1, DCVRAMSize);
  ARAM := Allocate(2, DCARAMSize);
  Boot := Allocate(3, DCBootSize);
  Flash := Allocate(4, DCFlashSize);
  BuildPages;
end;

destructor TDCMemory.Destroy;
begin
  for var I := 0 to High(FBlocks) do
    FreeMem(FBlocks[I]);
  inherited;
end;

function TDCMemory.Allocate(Index, Size: Integer): PByte;
begin
  // 64 KiB alignment keeps every page pointer naturally aligned.
  GetMem(FBlocks[Index], Size + 65536);
  Result := PByte((NativeUInt(FBlocks[Index]) + 65535) and not NativeUInt(65535));
  FillChar(Result^, Size, 0);
end;

procedure TDCMemory.BuildPages;
begin
  FillChar(ReadPages, SizeOf(ReadPages), 0);
  FillChar(WritePages, SizeOf(WritePages), 0);
  FillChar(Gens, SizeOf(Gens), 0);
  // Area 0: boot ROM (read-only) and flash (writes are commands); mirrored at 02000000.
  for var Mirror := 0 to 1 do
  begin
    var Base := Mirror * $200;
    for var P := 0 to 31 do
      ReadPages[Base + P] := Boot + P * 65536;
    for var P := 0 to 1 do
      ReadPages[Base + $20 + P] := Flash + P * 65536;
  end;
  // Area 1: the 32-bit VRAM view at 05000000 and 07000000, mirrored every 8 MiB.
  for var Area in [$0500, $0700] do
    for var P := 0 to 255 do
    begin
      var Offset := (P and $7F) * 65536;
      ReadPages[Area + P] := VRAM + Offset;
      WritePages[Area + P] := VRAM + Offset;
      Gens[Area + P] := @VRAMGens[(P and $7F) * 16];
    end;
  // Area 3: 16 MiB system RAM mirrored four times.
  for var P := $0C00 to $0FFF do
  begin
    var Offset := (P and $FF) * 65536;
    ReadPages[P] := RAM + Offset;
    WritePages[P] := RAM + Offset;
    Gens[P] := @RAMGens[(P and $FF) * 16];
  end;
end;

procedure TDCMemory.Observe(Offset, Size: Cardinal);
begin
  if Assigned(Barrier) and (Offset < PendingLast) and (Offset + Size > PendingFirst) then
    Barrier;
end;

procedure TDCMemory.MapVRAMPages(First, Last: Cardinal; Direct: Boolean);
begin
  if Last <= First then
    Exit;
  for var P := Integer(First shr 16) to Integer((Last - 1) shr 16) and $7F do
    for var Area in [$0500, $0700] do
      for var Mirror in [0, 128] do
      begin
        var Page := Area + Mirror + P;
        if Direct then
        begin
          ReadPages[Page] := VRAM + P * 65536;
          WritePages[Page] := VRAM + P * 65536;
        end
        else
        begin
          ReadPages[Page] := nil;
          WritePages[Page] := nil;
        end;
      end;
end;

class function TDCMemory.VRAM64(Offset: Cardinal): Cardinal;
begin
  Result := ((Offset and $7FFFF8) shr 1) or (Offset and 3) or ((Offset and 4) shl 20);
end;

procedure TDCMemory.TouchVRAM(Offset, Size: Cardinal);
begin
  var First := (Offset and $7FFFFF) shr 12;
  var Last := ((Offset + Size - 1) and $7FFFFF) shr 12;
  Inc(VRAMGens[First]);
  if Last <> First then
    Inc(VRAMGens[Last]);
end;

procedure TDCMemory.TouchRAM(Offset, Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var Page := (Offset and $FFFFFF) shr 12;
  var Last := ((Offset + Size - 1) and $FFFFFF) shr 12;
  repeat
    Inc(RAMGens[Page]);
    if Page = Last then
      Break;
    Page := (Page + 1) and High(RAMGens);
  until False;
end;

function TDCMemory.VRAMRead32(Offset: Cardinal): Cardinal;
begin
  Observe(Offset and $7FFFFC, 4);
  Result := PCardinal(VRAM + (Offset and $7FFFFC))^;
end;

procedure TDCMemory.VRAMWrite32(Offset, Value: Cardinal);
begin
  Observe(Offset and $7FFFFC, 4);
  PCardinal(VRAM + (Offset and $7FFFFC))^ := Value;
  Inc(VRAMGens[(Offset and $7FFFFF) shr 12]);
end;

function TDCMemory.VRAMRead64Path(Offset: Cardinal; Size: Integer): UInt64;
begin
  Offset := Offset and $7FFFFF;
  if Assigned(Barrier) then
  begin
    Observe(VRAM64(Offset) and not Cardinal(3), 4);
    Observe(VRAM64(Offset + 4) and not Cardinal(3), 4);
  end;
  case Size of
    1:
      Result := (VRAM + VRAM64(Offset))^;
    2:
      Result := PWord(VRAM + VRAM64(Offset))^;
    4:
      Result := PCardinal(VRAM + VRAM64(Offset))^;
  else
    Result := PCardinal(VRAM + VRAM64(Offset))^ or (UInt64(PCardinal(VRAM + VRAM64(Offset + 4))^) shl 32);
  end;
end;

procedure TDCMemory.VRAMWrite64Path(Offset: Cardinal; Value: UInt64; Size: Integer);
begin
  Offset := Offset and $7FFFFF;
  if Assigned(Barrier) then
  begin
    Observe(VRAM64(Offset) and not Cardinal(3), 4);
    Observe(VRAM64(Offset + 4) and not Cardinal(3), 4);
  end;
  var Linear := VRAM64(Offset);
  case Size of
    1:
      (VRAM + Linear)^ := Byte(Value);
    2:
      PWord(VRAM + Linear)^ := Word(Value);
    4:
      PCardinal(VRAM + Linear)^ := Cardinal(Value);
  else
    begin
      PCardinal(VRAM + Linear)^ := Cardinal(Value);
      var High := VRAM64(Offset + 4);
      PCardinal(VRAM + High)^ := Cardinal(Value shr 32);
      Inc(VRAMGens[High shr 12]);
    end;
  end;
  Inc(VRAMGens[Linear shr 12]);
end;

procedure TDCMemory.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(RAM^, DCRAMSize);
  Archive.Field(VRAM^, DCVRAMSize);
  Archive.Field(ARAM^, DCARAMSize);
  Archive.Field(Flash^, DCFlashSize);
  if Archive.Loading then
  begin
    for var I := 0 to High(RAMGens) do
      Inc(RAMGens[I]);
    for var I := 0 to High(VRAMGens) do
      Inc(VRAMGens[I]);
  end;
end;

end.

