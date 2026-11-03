unit PSP.SysMem;

// Memory partitions: an ordered list of free and used blocks. Allocation from
// the low end, the high end or at a fixed address, with alignment.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types;

type
  TPSPAllocKind = (akLow, akHigh, akAddress);

  TPSPBlock = record
    Address, Size: Cardinal;
    Used: Boolean;
    Tag: string;
  end;

  TPSPPartition = class
  private
    FBase, FSize: Cardinal;
    FBlocks: TList<TPSPBlock>;
    FId: Integer;
    procedure Merge;
  public
    constructor Create(Id: Integer; Base, Size: Cardinal);
    destructor Destroy; override;
    procedure Reset;
    // Returns 0 when there is no room.
    function Alloc(Size: Cardinal; Kind: TPSPAllocKind; Address: Cardinal = 0; Alignment: Cardinal = 256; const Tag: string = ''): Cardinal;
    function FreeBlock(Address: Cardinal): Boolean;
    function BlockSize(Address: Cardinal): Cardinal;
    function Contains(Address: Cardinal): Boolean;
    function FreeTotal: Cardinal;
    function LargestFree: Cardinal;
    function Describe: string;
    property Base: Cardinal read FBase;
    property Size: Cardinal read FSize;
    property Id: Integer read FId;
  end;

implementation

constructor TPSPPartition.Create(Id: Integer; Base, Size: Cardinal);
begin
  inherited Create;
  FId := Id;
  FBase := Base;
  FSize := Size;
  FBlocks := TList<TPSPBlock>.Create;
  Reset;
end;

destructor TPSPPartition.Destroy;
begin
  FBlocks.Free;
  inherited;
end;

procedure TPSPPartition.Reset;
begin
  FBlocks.Clear;
  var B := Default(TPSPBlock);
  B.Address := FBase;
  B.Size := FSize;
  FBlocks.Add(B);
end;

procedure TPSPPartition.Merge;
begin
  var I := 0;
  while I < FBlocks.Count - 1 do
  begin
    if not FBlocks[I].Used and not FBlocks[I + 1].Used then
    begin
      var B := FBlocks[I];
      B.Size := B.Size + FBlocks[I + 1].Size;
      FBlocks[I] := B;
      FBlocks.Delete(I + 1);
    end
    else
      Inc(I);
  end;
  I := 0;
  while I < FBlocks.Count do
    if FBlocks[I].Size = 0 then
      FBlocks.Delete(I)
    else
      Inc(I);
end;

function TPSPPartition.Alloc(Size: Cardinal; Kind: TPSPAllocKind; Address, Alignment: Cardinal; const Tag: string): Cardinal;

  function Split(Index: Integer; Start, Count: Cardinal): Cardinal;
  begin
    var B := FBlocks[Index];
    var Before := Start - B.Address;
    var After := B.Address + B.Size - (Start + Count);
    var Used := Default(TPSPBlock);
    Used.Address := Start;
    Used.Size := Count;
    Used.Used := True;
    Used.Tag := Tag;
    FBlocks.Delete(Index);
    var At := Index;
    if Before > 0 then
    begin
      var F := Default(TPSPBlock);
      F.Address := B.Address;
      F.Size := Before;
      FBlocks.Insert(At, F);
      Inc(At);
    end;
    FBlocks.Insert(At, Used);
    Inc(At);
    if After > 0 then
    begin
      var F := Default(TPSPBlock);
      F.Address := Start + Count;
      F.Size := After;
      FBlocks.Insert(At, F);
    end;
    Result := Start;
  end;

begin
  Result := 0;
  if (Size = 0) or (Size > FSize) then
    Exit;
  if Alignment < 256 then
    Alignment := 256;
  Size := AlignUp(Size, 256);
  case Kind of
    akLow:
      for var I := 0 to FBlocks.Count - 1 do
      begin
        var B := FBlocks[I];
        if B.Used then
          Continue;
        var Start := AlignUp(B.Address, Alignment);
        if (Start >= B.Address) and (Start - B.Address <= B.Size) and (B.Size - (Start - B.Address) >= Size) then
          Exit(Split(I, Start, Size));
      end;
    akHigh:
      for var I := FBlocks.Count - 1 downto 0 do
      begin
        var B := FBlocks[I];
        if B.Used or (B.Size < Size) then
          Continue;
        var Start := (B.Address + B.Size - Size) and not (Alignment - 1);
        if Start >= B.Address then
          Exit(Split(I, Start, Size));
      end;
    akAddress:
      begin
        var Start := Address and not Cardinal(255);
        var Count := AlignUp(Address + Size, 256) - Start;
        for var I := 0 to FBlocks.Count - 1 do
        begin
          var B := FBlocks[I];
          if B.Used then
            Continue;
          if (Start >= B.Address) and (Start + Count <= B.Address + B.Size) then
            Exit(Split(I, Start, Count));
        end;
      end;
  end;
end;

function TPSPPartition.FreeBlock(Address: Cardinal): Boolean;
begin
  for var I := 0 to FBlocks.Count - 1 do
    if FBlocks[I].Used and (FBlocks[I].Address = Address) then
    begin
      var B := FBlocks[I];
      B.Used := False;
      B.Tag := '';
      FBlocks[I] := B;
      Merge;
      Exit(True);
    end;
  Result := False;
end;

function TPSPPartition.BlockSize(Address: Cardinal): Cardinal;
begin
  for var B in FBlocks do
    if B.Used and (B.Address = Address) then
      Exit(B.Size);
  Result := 0;
end;

function TPSPPartition.Contains(Address: Cardinal): Boolean;
begin
  Result := (Address >= FBase) and (Address - FBase < FSize);
end;

function TPSPPartition.FreeTotal: Cardinal;
begin
  Result := 0;
  for var B in FBlocks do
    if not B.Used then
      Inc(Result, B.Size);
end;

function TPSPPartition.LargestFree: Cardinal;
begin
  Result := 0;
  for var B in FBlocks do
    if not B.Used and (B.Size > Result) then
      Result := B.Size;
end;

function TPSPPartition.Describe: string;
begin
  Result := '';
  for var B in FBlocks do
    Result := Result + Format('%.8x %.8x %s %s'#10, [B.Address, B.Size, BoolToStr(B.Used, True), B.Tag]);
end;

end.

