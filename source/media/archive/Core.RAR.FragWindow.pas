unit Core.RAR.FragWindow;
{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}
{$POINTERMATH ON}

// Free Pascal port of Unrar
// Unrar by Alexander Roshal
// Port by www.xelitan.com
// License: MIT
// The code cannot be used to recreate RAR compression

// TFragmentedWindow — segmented sliding-dictionary fallback
// Used when a single large contiguous window cannot be allocated.
// (unpack50frag.cpp)

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  Core.RAR.Types;

type
  TFragmentedWindow = class
  private
    const
      MAX_MEM_BLOCKS = 32;
    var
      FMem: array[0..MAX_MEM_BLOCKS - 1] of PByte;
      FMemSize: array[0..MAX_MEM_BLOCKS - 1] of NativeUInt;
      FLastAllocated: NativeUInt;
    procedure Reset;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Init(WinSize: NativeUInt);

    // Access a single byte (read or write via returned pointer).
    function BytePtr(Item: NativeUInt): PByte; {$IFDEF FPC} inline;{$ENDIF}

    // Copy a match from (UnpPtr−Distance) into UnpPtr, advancing UnpPtr.
    procedure CopyString(ALength: LongWord; Distance: NativeUInt; var UnpPtr: NativeUInt; FirstWinDone: Boolean; MaxWinSize: NativeUInt);

    // Copy Size bytes starting at WinPos into Dest.
    procedure CopyData(Dest: PByte; WinPos, Size: NativeUInt);

    // Largest contiguous readable block starting at StartPos, up to RequiredSize.
    function GetBlockSize(StartPos, RequiredSize: NativeUInt): NativeUInt;

    function GetWinSize: NativeUInt; {$IFDEF FPC} inline;{$ENDIF}
  end;

implementation

uses
  SysUtils;

constructor TFragmentedWindow.Create;
begin
  FillChar(FMem, SizeOf(FMem), 0);
  FillChar(FMemSize, SizeOf(FMemSize), 0);
  FLastAllocated := 0;
end;

destructor TFragmentedWindow.Destroy;
begin
  Reset;
  inherited;
end;

procedure TFragmentedWindow.Reset;
var
  I: Integer;
begin
  FLastAllocated := 0;
  for I := 0 to MAX_MEM_BLOCKS - 1 do
    if FMem[I] <> nil then
    begin
      FreeMem(FMem[I]);
      FMem[I] := nil;
    end;
end;

procedure TFragmentedWindow.Init(WinSize: NativeUInt);
var
  BlockNum: Integer;
  TotalSize, Size, MinSize: NativeUInt;
  NewMem: PByte;
begin
  Reset;
  BlockNum := 0;
  TotalSize := 0;
  while (TotalSize < WinSize) and (BlockNum < MAX_MEM_BLOCKS) do
  begin
    Size := WinSize - TotalSize;
    // Minimum acceptable: at least "remaining / attempts_left" and 4 MB.
    MinSize := Size div LongWord(MAX_MEM_BLOCKS - BlockNum);
    if MinSize < $400000 then
      MinSize := $400000;
    NewMem := nil;
    while Size >= MinSize do
    begin
      try
        GetMem(NewMem, Size);
        Break;
      except
        on EOutOfMemory do
          NewMem := nil;
      end;
      Dec(Size, Size div 32);
    end;
    if NewMem = nil then
      raise EOutOfMemory.Create('FragmentedWindow');
    FillChar(NewMem^, Size, 0);
    FMem[BlockNum] := NewMem;
    TotalSize := TotalSize + Size;
    FMemSize[BlockNum] := TotalSize;
    Inc(BlockNum);
  end;
  if TotalSize < WinSize then
    raise EOutOfMemory.Create('FragmentedWindow');
  FLastAllocated := WinSize;
end;

function TFragmentedWindow.BytePtr(Item: NativeUInt): PByte;
var
  I: Integer;
begin
  if Item < FMemSize[0] then
  begin
    Result := FMem[0] + Item;
    Exit;
  end;
  for I := 1 to MAX_MEM_BLOCKS - 1 do
    if Item < FMemSize[I] then
    begin
      Result := FMem[I] + (Item - FMemSize[I - 1]);
      Exit;
    end;
  Result := FMem[0]; // must never happen
end;

procedure TFragmentedWindow.CopyString(ALength: LongWord; Distance: NativeUInt; var UnpPtr: NativeUInt; FirstWinDone: Boolean; MaxWinSize: NativeUInt);
var
  SrcPtr: NativeUInt;
begin
  SrcPtr := UnpPtr - Distance;
  if Distance > UnpPtr then
  begin
    Inc(SrcPtr, MaxWinSize);
    if (Distance > MaxWinSize) or not FirstWinDone then
    begin
      while ALength > 0 do
      begin
        BytePtr(UnpPtr)^ := 0;
        Inc(UnpPtr);
        if UnpPtr >= MaxWinSize then
          Dec(UnpPtr, MaxWinSize);
        Dec(ALength);
      end;
      Exit;
    end;
  end;
  while ALength > 0 do
  begin
    BytePtr(UnpPtr)^ := BytePtr(SrcPtr)^;
    Inc(SrcPtr);
    if SrcPtr >= MaxWinSize then
      Dec(SrcPtr, MaxWinSize);
    Inc(UnpPtr);
    if UnpPtr >= MaxWinSize then
      Dec(UnpPtr, MaxWinSize);
    Dec(ALength);
  end;
end;

procedure TFragmentedWindow.CopyData(Dest: PByte; WinPos, Size: NativeUInt);
var
  I: NativeUInt;
begin
  for I := 0 to Size - 1 do
    Dest[I] := BytePtr(WinPos + I)^;
end;

function TFragmentedWindow.GetBlockSize(StartPos, RequiredSize: NativeUInt): NativeUInt;
var
  I: Integer;
begin
  for I := 0 to MAX_MEM_BLOCKS - 1 do
    if StartPos < FMemSize[I] then
    begin
      if FMemSize[I] - StartPos < RequiredSize then
        Result := FMemSize[I] - StartPos
      else
        Result := RequiredSize;
      Exit;
    end;
  Result := 0; // must never happen
end;

function TFragmentedWindow.GetWinSize: NativeUInt;
begin
  Result := FLastAllocated;
end;

end.

