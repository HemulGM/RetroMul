unit PSP.VariablePool;

// PSP VPL header/block layout, with reference to PPSSPP sceKernelMemory.cpp.
// Copyright (c) 2012- PPSSPP Project and contributors. GPL-3.0-or-later.
// See PSP.PRX-LICENSE.md.
interface

uses
  PSP.Memory;

type
  TPSPVariablePool = class
  private
    FMemory: TPSPMemory;
    FBase, FSize: Cardinal;
    procedure ValidateBlock(Address: Cardinal);
  public
    constructor Create(Memory: TPSPMemory; Address, Size: Cardinal);
    function Allocate(Size: Cardinal): Cardinal;
    function Release(Address: Cardinal): Boolean;
    function FreeSize: Cardinal;
    property Size: Cardinal read FSize;
  end;

implementation

uses
  System.SysUtils;

constructor TPSPVariablePool.Create(Memory: TPSPMemory; Address, Size: Cardinal);
begin
  inherited Create;
  FMemory := Memory;
  FBase := Address;
  FSize := Size;
  if (Size < $38) or (Size and 7 <> 0) or not Memory.IsValid(Address, Size) then
    raise EPSPMemory.Create('PSP: invalid VPL memory extent');
  Memory.Zero(Address, 32);
  Memory.Write32(Address, Address);
  Memory.Write32(Address + 4, Address);
  Memory.Write32(Address + 8, Address + 7);
  Memory.Write32(Address + 12, Size - 8);
  Memory.Write32(Address + 20, Address + 24);
  Memory.Write32(Address + 24, Address + Size - 8);
  Memory.Write32(Address + 28, (Size - $20) div 8);
  Memory.Write32(Address + Size - 8, Address + 24);
  Memory.Write32(Address + Size - 4, 0);
end;

procedure TPSPVariablePool.ValidateBlock(Address: Cardinal);
begin
  if (Address < FBase + 24) or (Address > FBase + FSize - 8) or (Address and 7 <> 0) then
    raise EPSPMemory.Create('PSP: corrupt VPL block chain');
end;

function TPSPVariablePool.FreeSize: Cardinal;
begin
  var Allocated := UInt64(FMemory.Read32(FBase + 16)) * 8;
  if Allocated > FSize - $20 then
    raise EPSPMemory.Create('PSP: corrupt VPL accounting');
  Result := FSize - $20 - Cardinal(Allocated);
end;

function TPSPVariablePool.Allocate(Size: Cardinal): Cardinal;
begin
  Result := $FFFFFFFF;
  if (Size = 0) or (Size > FSize - $20) then
    Exit;
  var Blocks := (Size + 7) div 8 + 1;
  var Start := FMemory.Read32(FBase + 20);
  ValidateBlock(Start);
  var Previous := Start;
  for var Limit := 0 to FSize div 8 do
  begin
    var Block := FMemory.Read32(Previous);
    ValidateBlock(Block);
    var Available := FMemory.Read32(Block + 4);
    if Available > FSize div 8 then
      raise EPSPMemory.Create('PSP: corrupt VPL block size');
    if Available > Blocks then
    begin
      Dec(Available, Blocks);
      FMemory.Write32(Block + 4, Available);
      var Prefix := Block;
      Inc(Block, Available * 8);
      ValidateBlock(Block);
      FMemory.Write32(Block, Prefix);
      FMemory.Write32(Block + 4, Blocks);
      Available := Blocks;
    end;
    if Available = Blocks then
    begin
      FMemory.Write32(FBase + 16, FMemory.Read32(FBase + 16) + Blocks);
      FMemory.Write32(Previous, FMemory.Read32(Block));
      FMemory.Write32(FBase + 20, Previous);
      FMemory.Write32(Block, FBase + 8);
      Exit(Block + 8);
    end;
    Previous := Block;
    if Previous = Start then
      Exit;
  end;
  raise EPSPMemory.Create('PSP: cyclic VPL free list');
end;

function TPSPVariablePool.Release(Address: Cardinal): Boolean;
begin
  Result := False;
  if (Address < FBase + 32) or (Address >= FBase + FSize - 8) or (Address and 7 <> 0) then
    Exit;
  var Block := Address - 8;
  var Blocks := FMemory.Read32(Block + 4);
  if (FMemory.Read32(Block) <> FBase + 8) or (Blocks = 0) or
    (Blocks > FMemory.Read32(FBase + 16)) or (UInt64(Block) + UInt64(Blocks) * 8 > UInt64(FBase) + FSize - 8) then
    Exit;
  var Last := FBase + FSize - 8;
  var Previous := Last;
  for var Limit := 0 to FSize div 8 do
  begin
    var Next := FMemory.Read32(Previous);
    ValidateBlock(Next);
    if Next = Block then
      Exit;
    if Next > Block then
    begin
      FMemory.Write32(FBase + 16, FMemory.Read32(FBase + 16) - Blocks);
      FMemory.Write32(FBase + 20, Previous);
      FMemory.Write32(Block, Next);
      if (Block + Blocks * 8 = Next) and (FMemory.Read32(Next + 4) <> 0) then
      begin
        Inc(Blocks, FMemory.Read32(Next + 4));
        FMemory.Write32(Block, FMemory.Read32(Next));
        FMemory.Write32(Block + 4, Blocks);
      end;
      var PreviousBlocks := FMemory.Read32(Previous + 4);
      if Previous + PreviousBlocks * 8 = Block then
      begin
        FMemory.Write32(Previous, FMemory.Read32(Block));
        FMemory.Write32(Previous + 4, PreviousBlocks + Blocks);
      end
      else
        FMemory.Write32(Previous, Block);
      Exit(True);
    end;
    Previous := Next;
    if Previous = Last then
      Exit;
  end;
  raise EPSPMemory.Create('PSP: cyclic VPL release chain');
end;

end.

