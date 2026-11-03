unit Core.RAR.SubAlloc;
{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}
{$POINTERMATH ON}

// Free Pascal port of Unrar
// Unrar by Alexander Roshal
// Port by www.xelitan.com
// License: MIT
// The code cannot be used to recreate RAR compression

//  TSubAllocator — PPMd sub-allocator (suballoc.hpp / suballoc.cpp)
//  Dmitry Shkarin's original code, translated to Free Pascal.

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  Core.RAR.Types;

type
  TSubAllocator = class
  public
    const
      N1 = 4;
      N2 = 4;
      N3 = 4;
      N4 = ( 128 + 3 - 1 * N1 - 2 * N2 - 3 * N3) div 4;
      N_INDEXES = N1 + N2 + N3 + N4;
  private
    type
      PRAR_NODE = ^TRAR_NODE;

      TRAR_NODE = record
        next: PRAR_NODE;
      end;
    var
      FSubAllocSize: LongInt;  // allocated size in bytes
      Indx2Units: array[0..N_INDEXES - 1] of Byte;
      Units2Indx: array[0..127] of Byte;
      GlueCount: Byte;
      HeapStart, LoUnit, HiUnit: PByte;
      FreeList: array[0..N_INDEXES - 1] of TRAR_NODE;
    procedure InsertNode(p: Pointer; indx: Integer); {$IFDEF FPC} inline;{$ENDIF}
    function RemoveNode(indx: Integer): Pointer;    {$IFDEF FPC} inline;{$ENDIF}
    function U2B(NU: Integer): LongWord;            {$IFDEF FPC} inline;{$ENDIF}
    procedure SplitBlock(pv: Pointer; OldIndx, NewIndx: Integer);
    procedure GlueFreeBlocks;
    function AllocUnitsRare(indx: Integer): Pointer;
    function MBPtr(Base: PRARPPM_MEM_BLK; Items: Integer): PRARPPM_MEM_BLK; {$IFDEF FPC} inline;{$ENDIF}
  public
    pText, UnitsStart, HeapEnd, FakeUnitsStart: PByte;

    constructor Create;
    destructor Destroy; override;

    procedure Clean;
    function StartSubAllocator(SASize: Integer): Boolean;
    procedure StopSubAllocator;
    procedure InitSubAllocator;

    function AllocContext: Pointer; {$IFDEF FPC} inline;{$ENDIF}
    function AllocUnits(NU: Integer): Pointer;
    function ExpandUnits(OldPtr: Pointer; OldNU: Integer): Pointer;
    function ShrinkUnits(OldPtr: Pointer; OldNU, NewNU: Integer): Pointer;
    procedure FreeUnits(ptr: Pointer; OldNU: Integer); {$IFDEF FPC} inline;{$ENDIF}

    function GetAllocatedMemory: LongInt;
  end;

implementation

// The "real" size of one PPM memory unit — max of RARPPM_CONTEXT and RARPPM_MEM_BLK.
// Both are packed records; on 64-bit each is 20 bytes, on 32-bit each is 12 bytes.
function UnitSize: LongWord; {$IFDEF FPC} inline;{$ENDIF}
begin
  if SizeOf(TRARPPM_CONTEXT) >= SizeOf(TRARPPM_MEM_BLK) then
    Result := SizeOf(TRARPPM_CONTEXT)
  else
    Result := SizeOf(TRARPPM_MEM_BLK);
end;

// ─────────────────────────────────────────────────────────────────────────────

constructor TSubAllocator.Create;
begin
  Clean;
end;

destructor TSubAllocator.Destroy;
begin
  StopSubAllocator;
  inherited;
end;

procedure TSubAllocator.Clean;
begin
  FSubAllocSize := 0;
  HeapStart := nil;
end;

// ── Private helpers ──────────────────────────────────────────────────────────

procedure TSubAllocator.InsertNode(p: Pointer; indx: Integer);
begin
  PRAR_NODE(p)^.next := FreeList[indx].next;
  FreeList[indx].next := PRAR_NODE(p);
end;

function TSubAllocator.RemoveNode(indx: Integer): Pointer;
var
  n: PRAR_NODE;
begin
  n := FreeList[indx].next;
  FreeList[indx].next := n^.next;
  Result := n;
end;

function TSubAllocator.U2B(NU: Integer): LongWord;
begin
  Result := LongWord(UnitSize) * LongWord(NU);
end;

function TSubAllocator.MBPtr(Base: PRARPPM_MEM_BLK; Items: Integer): PRARPPM_MEM_BLK;
begin
  Result := PRARPPM_MEM_BLK(PByte(Base) + U2B(Items));
end;

procedure TSubAllocator.SplitBlock(pv: Pointer; OldIndx, NewIndx: Integer);
var
  UDiff, i: Integer;
  p: PByte;
begin
  UDiff := Indx2Units[OldIndx] - Indx2Units[NewIndx];
  p := PByte(pv) + U2B(Indx2Units[NewIndx]);
  i := Units2Indx[UDiff - 1];
  if Indx2Units[i] <> UDiff then
  begin
    Dec(i);
    InsertNode(p, i);
    p := p + U2B(Indx2Units[i]);
    Dec(UDiff, Indx2Units[i]);
  end;
  InsertNode(p, Units2Indx[UDiff - 1]);
end;

// ── StartSubAllocator / StopSubAllocator ─────────────────────────────────────

procedure TSubAllocator.StopSubAllocator;
begin
  if FSubAllocSize <> 0 then
  begin
    FSubAllocSize := 0;
    FreeMem(HeapStart);
    HeapStart := nil;
  end;
end;

function TSubAllocator.StartSubAllocator(SASize: Integer): Boolean;
var
  t, AllocSize: LongWord;
begin
  t := LongWord(SASize) shl 20;
  if FSubAllocSize = LongInt(t) then
  begin
    Result := True;
    Exit;
  end;
  StopSubAllocator;

  // Scale the original 12-byte-unit-based size to our actual unit size.
  AllocSize := t div PPM_FIXED_UNIT * UnitSize + 2 * UnitSize;
  GetMem(HeapStart, AllocSize);
  if HeapStart = nil then
  begin
    Result := False;
    Exit;
  end;

  HeapEnd := HeapStart + AllocSize - UnitSize;
  FSubAllocSize := LongInt(t);
  Result := True;
end;

// ── InitSubAllocator ─────────────────────────────────────────────────────────

procedure TSubAllocator.InitSubAllocator;
var
  i, k: Integer;
  Size1, Size2, RealSize1, RealSize2: LongWord;
begin
  FillChar(FreeList, SizeOf(FreeList), 0);
  pText := HeapStart;

  // Size2: 7/8 of total, expressed in original 12-byte units.
  Size2 := PPM_FIXED_UNIT * (LongWord(FSubAllocSize) div 8 div PPM_FIXED_UNIT * 7);
  RealSize2 := Size2 div PPM_FIXED_UNIT * UnitSize;

  Size1 := LongWord(FSubAllocSize) - Size2;
  RealSize1 := Size1 div PPM_FIXED_UNIT * UnitSize + UnitSize;

  LoUnit := HeapStart + RealSize1;
  UnitsStart := LoUnit;
  FakeUnitsStart := HeapStart + Size1;
  HiUnit := LoUnit + RealSize2;

  k := 1;
  for i := 0 to N1 - 1 do
  begin
    Indx2Units[i] := k;
    Inc(k);
  end;
  Inc(k);
  for i := N1 to N1 + N2 - 1 do
  begin
    Indx2Units[i] := k;
    Inc(k, 2);
  end;
  Inc(k);
  for i := N1 + N2 to N1 + N2 + N3 - 1 do
  begin
    Indx2Units[i] := k;
    Inc(k, 3);
  end;
  Inc(k);
  for i := N1 + N2 + N3 to N_INDEXES - 1 do
  begin
    Indx2Units[i] := k;
    Inc(k, 4);
  end;

  GlueCount := 0;
  k := 0;
  for i := 0 to 127 do
  begin
    if Indx2Units[k] < i + 1 then
      Inc(k);
    Units2Indx[i] := k;
  end;
end;

// ── GlueFreeBlocks ───────────────────────────────────────────────────────────

procedure TSubAllocator.GlueFreeBlocks;
var
  s0: TRARPPM_MEM_BLK;
  p, p1: PRARPPM_MEM_BLK;
  i, sz: Integer;
begin
  if LoUnit <> HiUnit then
    LoUnit^ := 0;
  // Sentinel doubly-linked list head.
  s0.next := @s0;
  s0.prev := @s0;
  for i := 0 to N_INDEXES - 1 do
    while FreeList[i].next <> nil do
    begin
      p := PRARPPM_MEM_BLK(RemoveNode(i));
      // insertAt
      p^.next := s0.next;
      p^.prev := @s0;
      s0.next^.prev := p;
      s0.next := p;
      p^.Stamp := $FFFF;
      p^.NU := Indx2Units[i];
    end;

  // Merge adjacent free blocks.
  p := s0.next;
  while p <> @s0 do
  begin
    p1 := MBPtr(p, p^.NU);
    while (p1^.Stamp = $FFFF) and (Integer(p^.NU) + p1^.NU < $10000) do
    begin
      // p1.remove
      p1^.prev^.next := p1^.next;
      p1^.next^.prev := p1^.prev;
      Inc(p^.NU, p1^.NU);
      p1 := MBPtr(p, p^.NU);
    end;
    p := p^.next;
  end;

  // Re-insert merged blocks into free lists.
  p := s0.next;
  while p <> @s0 do
  begin
    // remove p from sentinel list
    p^.prev^.next := p^.next;
    p^.next^.prev := p^.prev;
    sz := p^.NU;
    while sz > 128 do
    begin
      InsertNode(p, N_INDEXES - 1);
      p := MBPtr(p, 128);
      Dec(sz, 128);
    end;
    i := Units2Indx[sz - 1];
    if Indx2Units[i] <> sz then
    begin
      Dec(i);
      InsertNode(MBPtr(p, sz - Indx2Units[i]), Indx2Units[i] - 1);
    end;
    InsertNode(p, i);
    p := s0.next; // restart (s0.next was modified)
  end;
end;

// ── AllocUnitsRare ───────────────────────────────────────────────────────────

function TSubAllocator.AllocUnitsRare(indx: Integer): Pointer;
var
  i: Integer;
begin
  if GlueCount = 0 then
  begin
    GlueCount := 255;
    GlueFreeBlocks;
    if FreeList[indx].next <> nil then
    begin
      Result := RemoveNode(indx);
      Exit;
    end;
  end;
  i := indx;
  repeat
    Inc(i);
    if i = N_INDEXES then
    begin
      Dec(GlueCount);
      if NativeInt(FakeUnitsStart) - NativeInt(pText) > Integer(PPM_FIXED_UNIT * Indx2Units[indx]) then
      begin
        Dec(FakeUnitsStart, Integer(PPM_FIXED_UNIT * Indx2Units[indx]));
        Dec(UnitsStart, Integer(U2B(Indx2Units[indx])));
        Result := UnitsStart;
        Exit;
      end;
      Result := nil;
      Exit;
    end;
  until FreeList[i].next <> nil;
  Result := RemoveNode(i);
  SplitBlock(Result, i, indx);
end;

// ── AllocUnits ───────────────────────────────────────────────────────────────

function TSubAllocator.AllocUnits(NU: Integer): Pointer;
var
  indx: Integer;
  RetVal: PByte;
begin
  indx := Units2Indx[NU - 1];
  if FreeList[indx].next <> nil then
  begin
    Result := RemoveNode(indx);
    Exit;
  end;
  RetVal := LoUnit;
  Inc(LoUnit, U2B(Indx2Units[indx]));
  if LoUnit <= HiUnit then
  begin
    Result := RetVal;
    Exit;
  end;
  Dec(LoUnit, U2B(Indx2Units[indx]));
  Result := AllocUnitsRare(indx);
end;

// ── AllocContext ──────────────────────────────────────────────────────────────

function TSubAllocator.AllocContext: Pointer;
begin
  if HiUnit <> LoUnit then
  begin
    Dec(HiUnit, UnitSize);
    Result := HiUnit;
    Exit;
  end;
  if FreeList[0].next <> nil then
  begin
    Result := RemoveNode(0);
    Exit;
  end;
  Result := AllocUnitsRare(0);
end;

// ── ExpandUnits / ShrinkUnits / FreeUnits ────────────────────────────────────

function TSubAllocator.ExpandUnits(OldPtr: Pointer; OldNU: Integer): Pointer;
var
  i0, i1: Integer;
begin
  i0 := Units2Indx[OldNU - 1];
  i1 := Units2Indx[OldNU];       // OldNU-1+1 = OldNU
  if i0 = i1 then
  begin
    Result := OldPtr;
    Exit;
  end;
  Result := AllocUnits(OldNU + 1);
  if Result <> nil then
  begin
    Move(OldPtr^, Result^, U2B(OldNU));
    InsertNode(OldPtr, i0);
  end;
end;

function TSubAllocator.ShrinkUnits(OldPtr: Pointer; OldNU, NewNU: Integer): Pointer;
var
  i0, i1: Integer;
begin
  i0 := Units2Indx[OldNU - 1];
  i1 := Units2Indx[NewNU - 1];
  if i0 = i1 then
  begin
    Result := OldPtr;
    Exit;
  end;
  if FreeList[i1].next <> nil then
  begin
    Result := RemoveNode(i1);
    Move(OldPtr^, Result^, U2B(NewNU));
    InsertNode(OldPtr, i0);
  end
  else
  begin
    SplitBlock(OldPtr, i0, i1);
    Result := OldPtr;
  end;
end;

procedure TSubAllocator.FreeUnits(ptr: Pointer; OldNU: Integer);
begin
  InsertNode(ptr, Units2Indx[OldNU - 1]);
end;

function TSubAllocator.GetAllocatedMemory: LongInt;
begin
  Result := FSubAllocSize;
end;

end.

