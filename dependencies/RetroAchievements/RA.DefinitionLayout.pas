unit RA.DefinitionLayout;

interface

uses
  System.Generics.Collections, RA.MemoryValues;

{$SCOPEDENUMS ON}

type
  TRADefinitionKind = (Trigger, Value, Leaderboard, RichPresence);

  // Measures rcheevos 12.5 caller-buffer storage, independent of the Delphi heap layout.
  TRADefinitionLayout = record
  private
    FOffset: NativeUInt;
  public
    constructor Create(Kind: TRADefinitionKind);
    procedure Add(Bytes, Alignment: NativeUInt);
    procedure AddGroup(Conditions: NativeUInt);
    procedure AddValue;
    procedure AddLookup;
    procedure AddLookupItem;
    procedure AddDisplay;
    procedure AddDisplayPart;
    function Finish(Memrefs: TRARuntimeMemrefs): Integer;
    property Offset: NativeUInt read FOffset;
  end;

  TRADefinitionStrings = class
  private
    type
      TEntry = record
        Text: UTF8String;
        Children: array[Boolean] of Integer;
      end;
  private
    FEntries: TList<TEntry>;
    FRoot: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function AddText(var Layout: TRADefinitionLayout; const Text: string; Unescape: Boolean = False): Integer;
    function GetText(Slot: Integer): string;
  end;

implementation

uses
  System.SysUtils;

constructor TRADefinitionLayout.Create(Kind: TRADefinitionKind);
const
  Header32: array[TRADefinitionKind] of Byte = (52, 60, 128, 48);
  Header64: array[TRADefinitionKind] of Byte = (80, 88, 200, 80);
begin
  FOffset := 0;
  if SizeOf(Pointer) = 8 then
    Add(Header64[Kind], 8)
  else
    Add(Header32[Kind], 4);
end;

procedure TRADefinitionLayout.Add(Bytes, Alignment: NativeUInt);
var
  AlignedOffset: NativeUInt;
begin
  if FOffset > NativeUInt(High(Integer)) - (Alignment - 1) then
    raise EOutOfMemory.Create('RetroAchievements definition is too large');
  AlignedOffset := (FOffset + Alignment - 1) and not (Alignment - 1);
  if Bytes > NativeUInt(High(Integer)) - AlignedOffset then
    raise EOutOfMemory.Create('RetroAchievements definition is too large');
  FOffset := AlignedOffset + Bytes;
end;

procedure TRADefinitionLayout.AddGroup(Conditions: NativeUInt);
var
  Header, ItemSize: NativeUInt;
begin
  if SizeOf(Pointer) = 8 then
  begin
    Header := 32;
    ItemSize := 56;
  end
  else
  begin
    Header := 24;
    ItemSize := 48;
  end;
  if Conditions = 0 then
    Add(Header, SizeOf(Pointer))
  else
  begin
    if Conditions > (NativeUInt(High(Integer)) - Header) div ItemSize then
      raise EOutOfMemory.Create('RetroAchievements condition group is too large');
    Add(Header + Conditions * ItemSize, 8);
  end;
end;

procedure TRADefinitionLayout.AddValue;
begin
  if SizeOf(Pointer) = 8 then
    Add(40, 8)
  else
    Add(28, 4);
end;

procedure TRADefinitionLayout.AddLookup;
begin
  if SizeOf(Pointer) = 8 then
    Add(40, 8)
  else
    Add(20, 4);
end;

procedure TRADefinitionLayout.AddLookupItem;
begin
  if SizeOf(Pointer) = 8 then
    Add(32, 8)
  else
    Add(20, 4);
end;

procedure TRADefinitionLayout.AddDisplay;
begin
  if SizeOf(Pointer) = 8 then
    Add(56, 8)
  else
    Add(32, 4);
end;

procedure TRADefinitionLayout.AddDisplayPart;
begin
  if SizeOf(Pointer) = 8 then
    Add(48, 8)
  else
    Add(40, 8);
end;

constructor TRADefinitionStrings.Create;
begin
  inherited Create;
  FEntries := TList<TEntry>.Create;
end;

destructor TRADefinitionStrings.Destroy;
begin
  FEntries.Free;
  inherited;
end;

function TRADefinitionStrings.AddText(var Layout: TRADefinitionLayout; const Text: string; Unescape: Boolean): Integer;
var
  Data, Existing: UTF8String;
  Node, Parent, Comparison, Index, Output: Integer;
  Right: Boolean;
  Entry: TEntry;
begin
  Data := UTF8String(Text);
  Node := FRoot;
  Parent := 0;
  Right := False;
  while Node <> 0 do
  begin
    Existing := FEntries[Node - 1].Text;
    Comparison := 0;
    Index := 1;
    while (Index <= Length(Data)) and (Index <= Length(Existing)) do
    begin
      Comparison := Byte(Data[Index]) - Byte(Existing[Index]);
      if Comparison <> 0 then
        Break;
      Inc(Index);
    end;
    if Comparison = 0 then
    begin
      if Length(Data) = Length(Existing) then
        Break;
      // rc_alloc_str compares the first length bytes, then the existing terminator.
      if Length(Data) < Length(Existing) then
        Comparison := Byte(Existing[Length(Data) + 1])
      else
        Comparison := Byte(Data[Length(Existing) + 1]);
    end;
    Parent := Node;
    Right := Comparison >= 0;
    Node := FEntries[Node - 1].Children[Right];
  end;
  if Node = 0 then
  begin
    Layout.Add(NativeUInt(Length(Data)) + 1, 1);
    Entry := Default(TEntry);
    Entry.Text := Data;
    Node := FEntries.Add(Entry) + 1;
    if Parent = 0 then
      FRoot := Node
    else
    begin
      Entry := FEntries[Parent - 1];
      Entry.Children[Right] := Node;
      FEntries[Parent - 1] := Entry;
    end;
  end;
  if Unescape then
  begin
    Entry := FEntries[Node - 1];
    Data := Entry.Text;
    Index := 1;
    Output := 0;
    while Index <= Length(Data) do
    begin
      if Data[Index] = '\' then
        Inc(Index);
      if Index <= Length(Data) then
      begin
        Inc(Output);
        Data[Output] := Data[Index];
      end;
      Inc(Index);
    end;
    SetLength(Data, Output);
    Entry.Text := Data;
    FEntries[Node - 1] := Entry;
  end;
  Result := Node;
end;

function TRADefinitionStrings.GetText(Slot: Integer): string;
begin
  if Slot = 0 then
    Exit('');
  Result := string(FEntries[Slot - 1].Text);
end;

function TRADefinitionLayout.Finish(Memrefs: TRARuntimeMemrefs): Integer;
begin
  if Memrefs.DirectCount <> 0 then
    Add(NativeUInt(Memrefs.DirectCount) * 16, 4);
  if Memrefs.ModifiedCount <> 0 then
    Add(NativeUInt(Memrefs.ModifiedCount) * 56, 8);
  Add(0, 8);
  Result := Integer(FOffset);
end;

end.

