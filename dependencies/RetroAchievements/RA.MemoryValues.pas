unit RA.MemoryValues;

interface

{$SCOPEDENUMS ON}

uses
  System.Generics.Collections, RA.Memory, RA.Progress;

type
  TRAMemorySize = (
    UInt8, UInt16, UInt24, UInt32, LowNibble, HighNibble,
    Bit0, Bit1, Bit2, Bit3, Bit4, Bit5, Bit6, Bit7, BitCount,
    UInt16BE, UInt24BE, UInt32BE,
    Float32, Float32BE, Double32, Double32BE, MBF32, MBF32LE
    );

  TRAValueHistory = (Current, Delta, Prior);

  TRAMemoryValue = record
    IsFloat: Boolean;
    case Boolean of
      False:
        (Unsigned: Cardinal);
      True:
        (Float: Single);
  end;

  TRAMemoryReference = record
    Address: Cardinal;
    Size: TRAMemorySize;
    History: TRAValueHistory;
    // Parses a memory address with its memory-size prefix and optional d/p modifier.
    class function TryParse(const Expression: string; var Position: Integer; out Reference: TRAMemoryReference): Boolean; static;
  end;

  PRAMemorySample = ^TRAMemorySample;

  TRAMemorySample = record
  private
    FCurrent, FPrior: Cardinal;
    FChanged: Boolean;
  public
    procedure Update(Value: Cardinal);
    procedure Restore(Current, Prior: Cardinal; Changed: Boolean);
    procedure WriteProgress(const IO: TRAProgressIO);
    procedure ReadProgress(const IO: TRAProgressIO);
    function Read(History: TRAValueHistory): Cardinal;
    property Current: Cardinal read FCurrent;
    property Prior: Cardinal read FPrior;
    property Changed: Boolean read FChanged;
  end;

  TRARuntimeMemref = class
  public
    Address, Size: Cardinal;
    Sample: TRAMemorySample;
    Invalidated: Boolean;
  end;

  TRAMemrefInvalidated = procedure(Memref: TRARuntimeMemref) of object;

  TRAIndirectAddress = reference to function: Cardinal;

  TRACalculatedValue = reference to function(ReadPrior, Restoring: Boolean; out Changed: Boolean): TRAMemoryValue;

  TRARuntimeMemrefs = class
  private
    type
      TModifiedMemref = class(TRARuntimeMemref)
      public
        Key: string;
        LegacyKeys: TArray<string>;
        ResolveAddress: TRAIndirectAddress;
        Calculate: TRACalculatedValue;
        procedure AddLegacyKeys(const Keys: array of string);
      end;
  private
    FEntries: TObjectList<TRARuntimeMemref>;
    FEntriesByKey: TDictionary<UInt64, TRARuntimeMemref>;
    FModifiedEntries: TObjectList<TModifiedMemref>;
    FModifiedByKey: TDictionary<string, TModifiedMemref>;
    function Find(Address, Size: Cardinal): TRARuntimeMemref;
    function AddModified(const Key: string): TModifiedMemref;
    function GetDirectCount: Integer;
    function GetModifiedCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(Address, Size: Cardinal; const Sample: TRAMemorySample);
    function GetOrAdd(Address, Size: Cardinal): TRARuntimeMemref;
    function GetOrAddIndirect(const Key: string; const LegacyKeys: array of string; Size: Cardinal; const ResolveAddress: TRAIndirectAddress): TRARuntimeMemref;
    function GetOrAddCalculated(const Key: string; const LegacyKeys: array of string; Size: TRAMemorySize; const Calculate: TRACalculatedValue): TRARuntimeMemref;
    function TryGet(Address, Size: Cardinal; out Sample: TRAMemorySample): Boolean;
    procedure Update(const ReadMemory: TRAMemoryRead; const OnInvalidated: TRAMemrefInvalidated);
    procedure InvalidateAddress(Address: Cardinal; const OnInvalidated: TRAMemrefInvalidated);
    function ValidateAddresses(const Validate: TRAAddressValidator; const OnInvalidated: TRAMemrefInvalidated): Boolean;
    function CheckDirectAddresses(const Validate: TRAAddressValidator): Boolean;
    procedure ClearSamples;
    procedure RestoreSamples(Source: TRARuntimeMemrefs);
    procedure RestoreModifiedSamples;
    procedure WriteModifiedTo(const IO: TRAProgressIO);
    procedure ReadModifiedFrom(const IO: TRAProgressIO);
    procedure WriteTo(const IO: TRAProgressIO);
    procedure ReadFrom(const IO: TRAProgressIO);
    property DirectCount: Integer read GetDirectCount;
    property ModifiedCount: Integer read GetModifiedCount;
  end;

function TryReadRAUnsignedLong(const Expression: string; var Position: Integer; Radix: Cardinal; out Value: UInt64): Boolean;

function RAProgressMemorySize(const Reference: TRAMemoryReference): Cardinal;

function TryReadRARawValue(const ReadMemory: TRAMemoryRead; Address: Cardinal; Size: TRAMemorySize; out Value: Cardinal): Boolean;

function MaskRARawValue(Raw: Cardinal; Size: TRAMemorySize): Cardinal;

function DecodeRAMemoryValue(Raw: Cardinal; Size: TRAMemorySize): TRAMemoryValue;

implementation

uses
  System.SysUtils;

type
  TRAMemoryLayout = record
    ByteCount: Byte;
    Mask: Cardinal;
  end;

const
  MemoryLayouts: array[TRAMemorySize] of TRAMemoryLayout = (
    (ByteCount: 1; Mask: $FF), (ByteCount: 2; Mask: $FFFF),
    (ByteCount: 4; Mask: $FFFFFF), (ByteCount: 4; Mask: $FFFFFFFF),
    (ByteCount: 1; Mask: $F), (ByteCount: 1; Mask: $F0),
    (ByteCount: 1; Mask: $01), (ByteCount: 1; Mask: $02),
    (ByteCount: 1; Mask: $04), (ByteCount: 1; Mask: $08),
    (ByteCount: 1; Mask: $10), (ByteCount: 1; Mask: $20),
    (ByteCount: 1; Mask: $40), (ByteCount: 1; Mask: $80),
    (ByteCount: 1; Mask: $FF), (ByteCount: 2; Mask: $FFFF),
    (ByteCount: 4; Mask: $FFFFFF), (ByteCount: 4; Mask: $FFFFFFFF),
    (ByteCount: 4; Mask: $FFFFFFFF), (ByteCount: 4; Mask: $FFFFFFFF),
    (ByteCount: 4; Mask: $FFFFFFFF), (ByteCount: 4; Mask: $FFFFFFFF),
    (ByteCount: 4; Mask: $FFFFFFFF), (ByteCount: 4; Mask: $FFFFFFFF)
  );
  NibbleBitCounts: array[0..15] of Byte = (0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4);

function UnsignedDigit(C: Char): Cardinal;
begin
  case C of
    '0'..'9':
      Result := Ord(C) - Ord('0');
    'A'..'F':
      Result := Ord(C) - Ord('A') + 10;
    'a'..'f':
      Result := Ord(C) - Ord('a') + 10;
  else
    Result := 16;
  end;
end;

function TryReadRAUnsignedLong(const Expression: string; var Position: Integer; Radix: Cardinal; out Value: UInt64): Boolean;
const
  // strtoul uses the platform's C unsigned long before callers narrow the result.
  {$IF Defined(MSWINDOWS) or not Defined(CPU64BITS)}
  Limit: UInt64 = High(Cardinal);
  {$ELSE}
  Limit: UInt64 = High(UInt64);
  {$ENDIF}
var
  Cursor, DigitsStart: Integer;
  Negative, Overflow: Boolean;
  Digit: Cardinal;
begin
  Value := 0;
  Cursor := Position;
  if (Cursor < 1) or not (Radix in [10, 16]) then
    Exit(False);
  while (Cursor <= Length(Expression)) and CharInSet(Expression[Cursor], [#9..#13, ' ']) do
    Inc(Cursor);
  Negative := (Cursor <= Length(Expression)) and (Expression[Cursor] = '-');
  if (Cursor <= Length(Expression)) and CharInSet(Expression[Cursor], ['+', '-']) then
    Inc(Cursor);

  if (Radix = 16) and (Cursor < Length(Expression)) and (Expression[Cursor] = '0') and
    CharInSet(Expression[Cursor + 1], ['x', 'X']) then
  begin
    {$IFDEF MSWINDOWS}
    // The Windows CRT reports no conversion for a hex prefix with no digits.
    Inc(Cursor, 2);
    {$ELSE}
    if (Cursor + 2 <= Length(Expression)) and (UnsignedDigit(Expression[Cursor + 2]) < 16) then
      Inc(Cursor, 2);
    {$ENDIF}
  end;

  DigitsStart := Cursor;
  Overflow := False;
  while Cursor <= Length(Expression) do
  begin
    Digit := UnsignedDigit(Expression[Cursor]);
    if Digit >= Radix then
      Break;
    if not Overflow then
    begin
      Overflow := Value > (Limit - Digit) div Radix;
      if not Overflow then
        Value := Value * Radix + Digit;
    end;
    Inc(Cursor);
  end;

  Result := Cursor <> DigitsStart;
  if not Result then
    Exit;
  if Overflow then
    Value := Limit
  else if Negative and (Value <> 0) then
    Value := Limit - Value + 1;
  Position := Cursor;
end;

function TryReadSize(const Expression: string; var Position: Integer; out Size: TRAMemorySize): Boolean;
begin
  if Position >= Length(Expression) then
    Exit(False);

  if (Expression[Position] = '0') and CharInSet(Expression[Position + 1], ['x', 'X']) then
  begin
    Inc(Position, 2);
    if Position > Length(Expression) then
      Exit(False);
    var Code := UpCase(Expression[Position]);
    case Code of
      'H':
        Size := TRAMemorySize.UInt8;
      ' ':
        Size := TRAMemorySize.UInt16;
      'W':
        Size := TRAMemorySize.UInt24;
      'X':
        Size := TRAMemorySize.UInt32;
      'L':
        Size := TRAMemorySize.LowNibble;
      'U':
        Size := TRAMemorySize.HighNibble;
      'M'..'T':
        Size := TRAMemorySize(Ord(TRAMemorySize.Bit0) + Ord(Code) - Ord('M'));
      'K':
        Size := TRAMemorySize.BitCount;
      'I':
        Size := TRAMemorySize.UInt16BE;
      'J':
        Size := TRAMemorySize.UInt24BE;
      'G':
        Size := TRAMemorySize.UInt32BE;
      '0'..'9', 'A'..'F':
        begin
          if (Code = '0') and (Position < Length(Expression)) and (Expression[Position + 1] = 'x') then
            Exit(False);
          Size := TRAMemorySize.UInt16;
          Exit(True);
        end;
    else
      Exit(False);
    end;
  end
  else if UpCase(Expression[Position]) = 'F' then
  begin
    Inc(Position);
    case UpCase(Expression[Position]) of
      'F':
        Size := TRAMemorySize.Float32;
      'B':
        Size := TRAMemorySize.Float32BE;
      'H':
        Size := TRAMemorySize.Double32;
      'I':
        Size := TRAMemorySize.Double32BE;
      'M':
        Size := TRAMemorySize.MBF32;
      'L':
        Size := TRAMemorySize.MBF32LE;
    else
      Exit(False);
    end;
  end
  else
    Exit(False);

  Inc(Position);
  Result := True;
end;

class function TRAMemoryReference.TryParse(const Expression: string; var Position: Integer; out Reference: TRAMemoryReference): Boolean;
var
  Cursor: Integer;
  Address: UInt64;
begin
  Reference := Default(TRAMemoryReference);
  Cursor := Position;
  if (Cursor < 1) or (Cursor > Length(Expression)) then
    Exit(False);

  case UpCase(Expression[Cursor]) of
    'D':
      Reference.History := TRAValueHistory.Delta;
    'P':
      Reference.History := TRAValueHistory.Prior;
  end;
  if Reference.History <> TRAValueHistory.Current then
    Inc(Cursor);
  if not TryReadSize(Expression, Cursor, Reference.Size) then
    Exit(False);
  Result := TryReadRAUnsignedLong(Expression, Cursor, 16, Address);
  if Result then
  begin
    if Address > High(Cardinal) then
      Address := High(Cardinal);
    Reference.Address := Cardinal(Address);
    Position := Cursor;
  end;
end;

const
  RCProgressMemrefChanged = $00010000;

procedure TRAMemorySample.Restore(Current, Prior: Cardinal; Changed: Boolean);
begin
  FCurrent := Current;
  FPrior := Prior;
  FChanged := Changed;
end;

function RAProgressMemorySize(const Reference: TRAMemoryReference): Cardinal;
var
  Shared: TRAMemorySize;
begin
  case MemoryLayouts[Reference.Size].ByteCount of
    1:
      Shared := TRAMemorySize.UInt8;
    2:
      Shared := TRAMemorySize.UInt16;
  else
    Shared := TRAMemorySize.UInt32;
  end;
  if (Reference.History = TRAValueHistory.Prior) and
    (MemoryLayouts[Reference.Size].Mask <> MemoryLayouts[Shared].Mask) then
    Result := Ord(Reference.Size)
  else
    Result := Ord(Shared);
end;

function TRARuntimeMemrefs.GetDirectCount: Integer;
begin
  Result := FEntries.Count;
end;

function TRARuntimeMemrefs.GetModifiedCount: Integer;
begin
  Result := FModifiedEntries.Count;
end;

constructor TRARuntimeMemrefs.Create;
begin
  inherited;
  FEntries := TObjectList<TRARuntimeMemref>.Create;
  FEntriesByKey := TDictionary<UInt64, TRARuntimeMemref>.Create;
  FModifiedEntries := TObjectList<TModifiedMemref>.Create;
  FModifiedByKey := TDictionary<string, TModifiedMemref>.Create;
end;

destructor TRARuntimeMemrefs.Destroy;
begin
  FModifiedByKey.Free;
  FModifiedEntries.Free;
  FEntriesByKey.Free;
  FEntries.Free;
  inherited;
end;

function TRARuntimeMemrefs.Find(Address, Size: Cardinal): TRARuntimeMemref;
begin
  FEntriesByKey.TryGetValue((UInt64(Address) shl 32) or Size, Result);
end;

function TRARuntimeMemrefs.GetOrAdd(Address, Size: Cardinal): TRARuntimeMemref;
begin
  Result := Find(Address, Size);
  if Result <> nil then
    Exit;
  Result := TRARuntimeMemref.Create;
  Result.Address := Address;
  Result.Size := Size;
  FEntries.Add(Result);
  FEntriesByKey.Add((UInt64(Address) shl 32) or Size, Result);
end;

function TRARuntimeMemrefs.AddModified(const Key: string): TModifiedMemref;
begin
  Result := TModifiedMemref.Create;
  Result.Key := Key;
  FModifiedEntries.Add(Result);
  FModifiedByKey.Add(Key, Result);
end;

procedure TRARuntimeMemrefs.TModifiedMemref.AddLegacyKeys(const Keys: array of string);
var
  Index: Integer;
begin
  for var StateKey in Keys do
  begin
    if StateKey = Key then
      Continue;
    Index := 0;
    while (Index < Length(LegacyKeys)) and (LegacyKeys[Index] <> StateKey) do
      Inc(Index);
    if Index = Length(LegacyKeys) then
      LegacyKeys := LegacyKeys + [StateKey];
  end;
end;

function TRARuntimeMemrefs.GetOrAddIndirect(const Key: string; const LegacyKeys: array of string; Size: Cardinal; const ResolveAddress: TRAIndirectAddress): TRARuntimeMemref;
var
  Entry: TModifiedMemref;
begin
  if not FModifiedByKey.TryGetValue(Key, Entry) then
  begin
    Entry := AddModified(Key);
    Entry.Size := Size;
    Entry.ResolveAddress := ResolveAddress;
  end;
  Entry.AddLegacyKeys(LegacyKeys);
  Result := Entry;
end;

function TRARuntimeMemrefs.GetOrAddCalculated(const Key: string; const LegacyKeys: array of string; Size: TRAMemorySize; const Calculate: TRACalculatedValue): TRARuntimeMemref;
var
  Entry: TModifiedMemref;
begin
  if not FModifiedByKey.TryGetValue(Key, Entry) then
  begin
    Entry := AddModified(Key);
    Entry.Size := Ord(Size);
    Entry.Calculate := Calculate;
  end;
  Entry.AddLegacyKeys(LegacyKeys);
  Result := Entry;
end;

procedure TRARuntimeMemrefs.Add(Address, Size: Cardinal; const Sample: TRAMemorySample);
begin
  if Find(Address, Size) = nil then
    GetOrAdd(Address, Size).Sample := Sample;
end;

function TRARuntimeMemrefs.TryGet(Address, Size: Cardinal; out Sample: TRAMemorySample): Boolean;
var
  Entry: TRARuntimeMemref;
begin
  Entry := Find(Address, Size);
  Result := Entry <> nil;
  if Result then
    Sample := Entry.Sample;
end;

procedure TRARuntimeMemrefs.Update(const ReadMemory: TRAMemoryRead; const OnInvalidated: TRAMemrefInvalidated);
var
  Raw: Cardinal;
  Size: TRAMemorySize;
  Value: TRAMemoryValue;
  Changed: Boolean;
begin
  for var Entry in FEntries do
  begin
    if Entry.Invalidated then
      Continue;
    Size := TRAMemorySize(Entry.Size);
    if TryReadRARawValue(ReadMemory, Entry.Address, Size, Raw) then
      Entry.Sample.Update(MaskRARawValue(Raw, Size))
    else
    begin
      Entry.Invalidated := True;
      OnInvalidated(Entry);
    end;
  end;

  // Register expressions in dependency order, including indirect reads.
  for var Entry in FModifiedEntries do
    if Assigned(Entry.Calculate) then
    begin
      Value := Entry.Calculate(False, False, Changed);
      Entry.Sample.Update(Value.Unsigned);
    end
    else
    begin
      Size := TRAMemorySize(Entry.Size);
      TryReadRARawValue(ReadMemory, Entry.ResolveAddress(), Size, Raw);
      Entry.Sample.Update(MaskRARawValue(Raw, Size));
    end;
end;

procedure TRARuntimeMemrefs.InvalidateAddress(Address: Cardinal; const OnInvalidated: TRAMemrefInvalidated);
begin
  for var Entry in FEntries do
    if Entry.Address = Address then
    begin
      Entry.Invalidated := True;
      OnInvalidated(Entry);
    end;
end;

function TRARuntimeMemrefs.ValidateAddresses(const Validate: TRAAddressValidator; const OnInvalidated: TRAMemrefInvalidated): Boolean;
begin
  Result := False;
  for var Entry in FEntries do
    if not Validate(Entry.Address) then
    begin
      Entry.Invalidated := True;
      OnInvalidated(Entry);
      Result := True;
    end;
end;

function TRARuntimeMemrefs.CheckDirectAddresses(const Validate: TRAAddressValidator): Boolean;
begin
  for var Entry in FEntries do
    if not Validate(Entry.Address) then
      Exit(False);
  Result := True;
end;

procedure TRARuntimeMemrefs.ClearSamples;
begin
  for var Entry in FEntries do
    Entry.Sample := Default(TRAMemorySample);
  for var Entry in FModifiedEntries do
    Entry.Sample := Default(TRAMemorySample);
end;

procedure TRARuntimeMemrefs.RestoreSamples(Source: TRARuntimeMemrefs);
var
  Sample: TRAMemorySample;
begin
  for var Entry in FEntries do
    if Source.TryGet(Entry.Address, Entry.Size, Sample) then
      Entry.Sample := Sample;
end;

procedure TRARuntimeMemrefs.RestoreModifiedSamples;
var
  Current, Prior: TRAMemoryValue;
  Changed, PriorChanged: Boolean;
begin
  for var Entry in FModifiedEntries do
    if Assigned(Entry.Calculate) then
    begin
      Current := Entry.Calculate(False, True, Changed);
      Prior := Entry.Calculate(True, True, PriorChanged);
      Entry.Sample.Restore(Current.Unsigned, Prior.Unsigned, Changed);
    end
    else
      Entry.Sample.Restore(Entry.Sample.Current, Entry.Sample.Prior, False);
end;

procedure TRARuntimeMemrefs.WriteModifiedTo(const IO: TRAProgressIO);
begin
  for var Entry in FModifiedEntries do
  begin
    IO.WriteString(Entry.Key);
    Entry.Sample.WriteProgress(IO);
  end;
end;

procedure TRARuntimeMemrefs.ReadModifiedFrom(const IO: TRAProgressIO);
var
  Key: string;
  Sample: TRAMemorySample;
  Saved: TDictionary<string, TRAMemorySample>;
begin
  Saved := TDictionary<string, TRAMemorySample>.Create;
  try
    while IO.Remaining > 0 do
    begin
      Key := IO.ReadString;
      Sample.ReadProgress(IO);
      Saved.AddOrSetValue(Key, Sample);
    end;
    for var Entry in FModifiedEntries do
      if Saved.TryGetValue(Entry.Key, Sample) then
        Entry.Sample := Sample
      else
        for var LegacyKey in Entry.LegacyKeys do
          if Saved.TryGetValue(LegacyKey, Sample) then
          begin
            Entry.Sample := Sample;
            Break;
          end;
  finally
    Saved.Free;
  end;
end;

procedure TRARuntimeMemrefs.WriteTo(const IO: TRAProgressIO);
begin
  for var Entry in FEntries do
  begin
    IO.WriteUInt(Entry.Address);
    IO.WriteUInt(Entry.Size or (Cardinal(Ord(Entry.Sample.Changed)) * RCProgressMemrefChanged));
    IO.WriteUInt(Entry.Sample.Current);
    IO.WriteUInt(Entry.Sample.Prior);
  end;
end;

procedure TRARuntimeMemrefs.ReadFrom(const IO: TRAProgressIO);
const
  RecordSize = 4 * SizeOf(Cardinal);
var
  Address, Flags, Current, Prior: Cardinal;
  Sample: TRAMemorySample;
begin
  // The C format counts whole records and skips the rest of the chunk.
  while IO.Remaining >= RecordSize do
  begin
    Address := IO.ReadUInt;
    Flags := IO.ReadUInt;
    Current := IO.ReadUInt;
    Prior := IO.ReadUInt;
    Sample.Restore(Current, Prior, (Flags and RCProgressMemrefChanged) <> 0);
    Add(Address, Flags and $FF, Sample);
  end;
end;

procedure TRAMemorySample.Update(Value: Cardinal);
begin
  FChanged := FCurrent <> Value;
  if FChanged then
  begin
    FPrior := FCurrent;
    FCurrent := Value;
  end;
end;

procedure TRAMemorySample.WriteProgress(const IO: TRAProgressIO);
begin
  IO.WriteUInt(FCurrent);
  IO.WriteUInt(FPrior);
  IO.WriteFlag(FChanged);
end;

procedure TRAMemorySample.ReadProgress(const IO: TRAProgressIO);
begin
  FCurrent := IO.ReadUInt;
  FPrior := IO.ReadUInt;
  FChanged := IO.ReadFlag;
end;

function TRAMemorySample.Read(History: TRAValueHistory): Cardinal;
begin
  if (History = TRAValueHistory.Prior) or ((History = TRAValueHistory.Delta) and FChanged) then
    Result := FPrior
  else
    Result := FCurrent;
end;

function TryReadRARawValue(const ReadMemory: TRAMemoryRead; Address: Cardinal; Size: TRAMemorySize; out Value: Cardinal): Boolean;
var
  Bytes: array[0..3] of Byte;
  Layout: TRAMemoryLayout;
begin
  Value := 0;
  Layout := MemoryLayouts[Size];
  if not Assigned(ReadMemory) or (ReadMemory(Address, @Bytes[0], Layout.ByteCount) <> Layout.ByteCount) then
    Exit(False);
  for var Index := 0 to Layout.ByteCount - 1 do
    Value := Value or (Cardinal(Bytes[Index]) shl (8 * Index));
  Result := True;
end;

function ReverseWord(Value: Cardinal): Cardinal;
begin
  Result := (Value shl 24) or ((Value and $FF00) shl 8) or
    ((Value shr 8) and $FF00) or (Value shr 24);
end;

function FloatFromFields(Mantissa: Cardinal; Exponent: Integer; Negative: Boolean): Single;
var
  Bits: Cardinal;
  Significand, Remainder, Halfway: Cardinal;
  Shift: Integer;
begin
  if Exponent > 127 then
  begin
    Bits := $7F800000;
    if Mantissa <> 0 then
      Bits := Bits or $400000;
  end
  else if Exponent > -127 then
    Bits := (Cardinal(Exponent + 127) shl 23) or Mantissa
  else if Exponent = -127 then
    Bits := Mantissa
  else if Exponent < -150 then
    Bits := 0
  else
  begin
    Shift := -126 - Exponent;
    Significand := $800000 or Mantissa;
    Halfway := Cardinal(1) shl (Shift - 1);
    Remainder := Significand and ((Halfway shl 1) - 1);
    Bits := Significand shr Shift;
    if (Remainder > Halfway) or ((Remainder = Halfway) and ((Bits and 1) <> 0)) then
      Inc(Bits);
  end;
  if Negative then
    Bits := Bits or $80000000;
  Move(Bits, Result, SizeOf(Result));
end;

function MaskRARawValue(Raw: Cardinal; Size: TRAMemorySize): Cardinal;
begin
  Result := Raw and MemoryLayouts[Size].Mask;
end;

function DecodeRAMemoryValue(Raw: Cardinal; Size: TRAMemorySize): TRAMemoryValue;
var
  Exponent: Integer;
  Mantissa: Cardinal;
  Negative: Boolean;
begin
  Result.IsFloat := Size >= TRAMemorySize.Float32;
  if Result.IsFloat then
  begin
    case Size of
      TRAMemorySize.Float32, TRAMemorySize.Float32BE:
        begin
          if Size = TRAMemorySize.Float32BE then
            Raw := ReverseWord(Raw);
          // The C decoder creates a canonical quiet NaN and retains its sign.
          if (Raw and $7FFFFFFF) > $7F800000 then
            Raw := (Raw and $80000000) or $7FC00000;
          Move(Raw, Result.Float, SizeOf(Raw));
        end;
      TRAMemorySize.Double32, TRAMemorySize.Double32BE:
        begin
          if Size = TRAMemorySize.Double32BE then
            Raw := ReverseWord(Raw);
          Result.Float := FloatFromFields((Raw and $FFFFF) shl 3,
            Integer((Raw shr 20) and $7FF) - 1023, (Raw and $80000000) <> 0);
        end;
      TRAMemorySize.MBF32, TRAMemorySize.MBF32LE:
        begin
          if Size = TRAMemorySize.MBF32 then
            Raw := ReverseWord(Raw);
          Exponent := Integer(Raw shr 24) - 129;
          Mantissa := Raw and $7FFFFF;
          Negative := (Raw and $800000) <> 0;
          if (Exponent = -129) and (Mantissa = 0) then
            Result.Float := FloatFromFields(0, -127, Negative)
          else
            Result.Float := FloatFromFields(Mantissa, Exponent, Negative);
        end;
    end;
    Exit;
  end;

  Raw := MaskRARawValue(Raw, Size);
  case Size of
    TRAMemorySize.HighNibble:
      Result.Unsigned := Raw shr 4;
    TRAMemorySize.Bit0..TRAMemorySize.Bit7:
      Result.Unsigned := Raw shr (Ord(Size) - Ord(TRAMemorySize.Bit0));
    TRAMemorySize.BitCount:
      Result.Unsigned := NibbleBitCounts[Raw and $F] + NibbleBitCounts[Raw shr 4];
    TRAMemorySize.UInt16BE:
      Result.Unsigned := ReverseWord(Raw) shr 16;
    TRAMemorySize.UInt24BE:
      Result.Unsigned := ReverseWord(Raw) shr 8;
    TRAMemorySize.UInt32BE:
      Result.Unsigned := ReverseWord(Raw);
  else
    Result.Unsigned := Raw;
  end;
end;

end.

