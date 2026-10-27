unit PSP.Relocations;

interface

uses
  System.SysUtils, PSP.Memory, PSP.Media;

type
  TPSPLoadSegment = record
    Loaded: Boolean;
    Address, Offset, FileSize, MemorySize: Cardinal;
  end;

procedure RelocatePSPRecords(const Data: TBytes; Offset, Size: Cardinal; Memory: TPSPMemory; const Segments: TArray<TPSPLoadSegment>);

procedure RelocatePSPCompressed(const Data: TBytes; Offset, Size, RelocationSegment: Cardinal; Memory: TPSPMemory; const Segments: TArray<TPSPLoadSegment>);

implementation

{$IFOPT Q+}{$DEFINE PSP_RELOCATION_CHECKS}{$ENDIF}
{$Q-}

function Add32(A, B: Cardinal): Cardinal;
begin
  Result := A + B;
end;
{$IFDEF PSP_RELOCATION_CHECKS}{$Q+}{$ENDIF}

procedure RelocatePSPRecords(const Data: TBytes; Offset, Size: Cardinal; Memory: TPSPMemory; const Segments: TArray<TPSPLoadSegment>);
type
  TRelocation = record
    Address, Relative, Op, Info: Cardinal;
    Kind: Integer;
  end;
begin
  if (Size mod 8 <> 0) or (UInt64(Offset) + Size > UInt64(Length(Data))) then
    raise EPSPFormat.Create('PSP: invalid relocation extent');
  var Records: TArray<TRelocation>;
  SetLength(Records, Size div 8);
  // Read original instructions before modifying either half of HI16/LO16 pairs.
  for var I := 0 to High(Records) do
  begin
    var Position := Int64(Offset) + Int64(I) * 8;
    var RelativeOffset := PSPLE32(Data, Position);
    var Info := PSPLE32(Data, Position + 4);
    var WriteSegment := (Info shr 8) and $FF;
    var RelativeSegment := (Info shr 16) and $FF;
    var Kind := Integer(Info and $FF);
    Records[I].Kind := Kind;
    Records[I].Info := Info;
    if Kind = 0 then
      Continue;
    if (WriteSegment >= Cardinal(Length(Segments))) or not Segments[WriteSegment].Loaded or
      (RelativeOffset > Segments[WriteSegment].MemorySize) or
      (Segments[WriteSegment].MemorySize - RelativeOffset < 4) then
      raise EPSPFormat.Create('PSP: relocation write outside loaded segment');
    if (RelativeSegment >= Cardinal(Length(Segments))) or not Segments[RelativeSegment].Loaded then
      raise EPSPFormat.Create('PSP: relocation refers to unloaded segment');
    Records[I].Address := Segments[WriteSegment].Address + RelativeOffset;
    Records[I].Relative := Segments[RelativeSegment].Address;
    Records[I].Op := Memory.Read32(Records[I].Address);
  end;
  for var I := 0 to High(Records) do
  begin
    var Item := Records[I];
    var Op := Item.Op;
    case Item.Kind of
      0:
        Continue;
      1, 6:
        Op := (Op and $FFFF0000) or (Add32(Op and $FFFF, Item.Relative) and $FFFF);
      2:
        Op := Add32(Op, Item.Relative);
      4:
        Op := (Op and $FC000000) or (Add32(Op and $03FFFFFF, Item.Relative shr 2) and $03FFFFFF);
      5:
        begin
          var Matched := False;
          for var J := I + 1 to High(Records) do
          begin
            if Records[J].Kind = 5 then
              Continue;
            if not (Records[J].Kind in [1, 6]) then
              Continue;
            var Address := Add32((Op and $FFFF) shl 16, Cardinal(Integer(SmallInt(Records[J].Op and $FFFF))));
            Address := Add32(Address, Item.Relative);
            Op := (Op and $FFFF0000) or (Add32(Address, $8000) shr 16);
            Matched := True;
            Break;
          end;
          if not Matched then
            raise EPSPFormat.Create('PSP: HI16 relocation has no LO16 pair');
        end;
      7:
        Continue; // GP-relative displacement is already resolved by the linker.
    else
      raise EPSPFormat.CreateFmt('PSP: unsupported relocation type %d', [Item.Kind]);
    end;
    Memory.Write32(Item.Address, Op);
  end;
end;

// PSP compressed relocation commands, ported with the PPSSPP ElfReader reference.
// Copyright PPSSPP Project and contributors. GPL-3.0-or-later.
{$Q-}{$R-}
procedure RelocatePSPCompressed(const Data: TBytes; Offset, Size, RelocationSegment: Cardinal; Memory: TPSPMemory; const Segments: TArray<TPSPLoadSegment>);
var
  Position, Limit: Integer;

  function Read8: Byte;
  begin
    if Position >= Limit then
      raise EPSPFormat.Create('PSP: truncated compressed relocation');
    Result := Data[Position];
    Inc(Position);
  end;

  function Read16: Word;
  begin
    Result := Read8;
    Result := Result or (Word(Read8) shl 8)
  end;

  function Read32: Cardinal;
  begin
    Result := Read16;
    Result := Result or (Cardinal(Read16) shl 16)
  end;

  function SignedShift(Value: Integer; Count: Cardinal): Integer;
  begin
    if Value < 0 then
      Result := Integer(not ((not Cardinal(Value)) shr Count))
    else
      Result := Value shr Count;
  end;

begin
  if (Size < 6) or (UInt64(Offset) + Size > UInt64(Length(Data))) then
    raise EPSPFormat.Create('PSP: invalid compressed relocation extent');
  Position := Offset;
  Limit := Offset + Size;
  Read16;
  var FlagBits := Read8;
  var TypeBits := Read8;
  var SegmentBits: Cardinal := 1;
  while (Cardinal(1) shl SegmentBits) < RelocationSegment do
    Inc(SegmentBits);
  if (FlagBits = 0) or (TypeBits = 0) or (FlagBits + SegmentBits + TypeBits >= 16) then
    raise EPSPFormat.Create('PSP: invalid compressed relocation bit widths');
  var FlagsOffset := Position;
  var FlagsCount := Read8;
  if (FlagsCount = 0) or (FlagsCount > Limit - FlagsOffset) then
    raise EPSPFormat.Create('PSP: invalid compressed relocation flags');
  Position := FlagsOffset + FlagsCount;
  var TypesOffset := Position;
  var TypesCount := Read8;
  if (TypesCount = 0) or (TypesCount > Limit - TypesOffset) then
    raise EPSPFormat.Create('PSP: invalid compressed relocation types');
  Position := TypesOffset + TypesCount;
  var WriteSegment: Cardinal := 0;
  var Base: Int64 := 0;
  var LastType: Integer := -1;
  var Low16: Integer := 0;
  while Position < Limit do
  begin
    var Command := Read16;
    var FlagIndex := Cardinal(Command) and ((Cardinal(1) shl FlagBits) - 1);
    var Segment := (Cardinal(Command) shr FlagBits) and ((Cardinal(1) shl SegmentBits) - 1);
    var TypeIndex := (Cardinal(Command) shr (FlagBits + SegmentBits)) and ((Cardinal(1) shl TypeBits) - 1);
    if (FlagIndex >= FlagsCount) or (TypeIndex >= TypesCount) then
      raise EPSPFormat.Create('PSP: invalid compressed relocation table index');
    var Flag := Data[FlagsOffset + Integer(FlagIndex)];
    var Kind := Data[TypesOffset + Integer(TypeIndex)];
    if Flag and 1 = 0 then
    begin
      WriteSegment := Segment;
      case Flag and 6 of
        0:
          Base := Command shr (SegmentBits + FlagBits);
        4:
          Base := Read32;
      else
        raise EPSPFormat.Create('PSP: invalid compressed relocation base mode');
      end;
      Continue;
    end;
    if (Segment >= Cardinal(Length(Segments))) or not Segments[Segment].Loaded then
      raise EPSPFormat.Create('PSP: compressed relocation refers to unloaded segment');
    case Flag and 6 of
      0:
        Inc(Base, SignedShift(SmallInt(Command), TypeBits + SegmentBits + FlagBits));
      2:
        begin
          var Delta := SignedShift(SmallInt(Command), TypeBits + SegmentBits + FlagBits);
          Delta := Integer((Cardinal(Delta) shl 16) or Read16);
          Inc(Base, Delta);
        end;
      4:
        Base := Read32;
    else
      raise EPSPFormat.Create('PSP: invalid compressed relocation offset mode');
    end;
    if (WriteSegment >= Cardinal(Length(Segments))) or not Segments[WriteSegment].Loaded or
      (Base < 0) or (UInt64(Base) + 4 > Segments[WriteSegment].MemorySize) then
      raise EPSPFormat.Create('PSP: compressed relocation write outside loaded segment');
    case Flag and $38 of
      0:
        Low16 := 0;
      8:
        if LastType <> 4 then
          Low16 := 0;
      $10:
        Low16 := SmallInt(Read16);
    else
      raise EPSPFormat.Create('PSP: invalid compressed relocation low-half mode');
    end;
    var Address := Segments[WriteSegment].Address + Cardinal(Base);
    var Relative := Segments[Segment].Address;
    var Op := Memory.Read32(Address);
    case Kind of
      0:
        ;
      1, 5:
        Op := (Op and $FFFF0000) or ((Op + Relative) and $FFFF);
      2:
        Inc(Op, Relative);
      3, 6, 7:
        begin
          Op := (Op and $FC000000) or (((Op and $03FFFFFF) + (Relative shr 2)) and $03FFFFFF);
          if Kind = 6 then
            Op := (Op and $03FFFFFF) or $08000000;
          if Kind = 7 then
            Op := (Op and $03FFFFFF) or $0C000000;
        end;
      4:
        begin
          var Target: Cardinal := (Op shl 16) + Cardinal(Low16) + Relative;
          if Target and $8000 <> 0 then
            Inc(Target, $10000);
          Op := (Op and $FFFF0000) or (Target shr 16);
        end;
    else
      raise EPSPFormat.CreateFmt('PSP: unknown compressed relocation kind %d', [Kind]);
    end;
    Memory.Write32(Address, Op);
    LastType := Kind;
  end;
end;

end.

