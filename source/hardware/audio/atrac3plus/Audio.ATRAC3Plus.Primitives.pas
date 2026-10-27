unit Audio.ATRAC3Plus.Primitives;

interface

uses
  System.SysUtils, FMXAudio.Transform;

type
  EATRACData = class(Exception);

  TATInts = TArray<Integer>;

  TATFloats = TArray<Single>;

  TATBools = TArray<Boolean>;

  TATBits = class
  private
    FData: TBytes;
    FPosition, FAnchor, FDirection: Integer;
  public
    constructor Create(const Data: TBytes);
    function Read(Count: Integer): Integer;
    function ReadBool: Boolean;
    function Read1: Integer;
    procedure Skip(Count: Integer);
    procedure Seek(ByteOffset: Integer);
    procedure SetDirection(Direction: Integer);
    function Peek(Count: Integer): Integer;
    function GetBitsLeft: Integer;
    function GetBytesRead: Integer;
  end;

  TATVLCNode = record
    Child: array[0..1] of Integer;
    Symbol: Integer;
    Leaf: Boolean;
  end;

  TATVLC = class
  private
    FNodes: TArray<TATVLCNode>;
    FMaximum: Integer;
  public
    Bits: Integer;
    function InitVLCSparse(NbBits, NbCodes: Integer; const Widths, Codes, Symbols: TATInts): Integer;
    procedure InitSparse(const Bits, Codes, Symbols: array of Integer; Count: Integer = -1);
    procedure InitCanonical(const Description, Symbols: array of Integer);
    function GetVLC2(Reader: TATBits; MaxDepth: Integer = 0): Integer;
  end;

  TATIMDCT = class
  private
    FSize: Integer;
    FTransform: TInverseMDCT;
    FTransformInput, FTransformOutput: TFloatSamples;
    FScale: Double;
    procedure Transform(const Input: TATFloats; InputOffset: Integer);
  public
    destructor Destroy; override;
    function MDCTInit(Bits: Integer; Inverse: Boolean; Scale: Double): Integer;
    procedure IMDCTCalc(const Output: TATFloats; OutputOffset: Integer; const Input: TATFloats; InputOffset: Integer);
    procedure IMDCTHalf(const Output: TATFloats; OutputOffset: Integer; const Input: TATFloats; InputOffset: Integer);
  end;

function ATSigned(Value: Integer; Bits: Integer): Integer;

function ATSar(Value, Shift: Integer): Integer;

procedure ATFill(const Data: TATInts; First, Last, Value: Integer); overload;

procedure ATFill(const Data: TATFloats; First, Last: Integer; Value: Single); overload;

procedure ATFill(const Data: TATBools; First, Last: Integer; Value: Boolean); overload;

procedure ATCopy(const Source: TATInts; SourceOffset: Integer; const Dest: TATInts; DestOffset, Count: Integer); overload;

procedure ATCopy(const Source: TATFloats; SourceOffset: Integer; const Dest: TATFloats; DestOffset, Count: Integer); overload;

procedure ATCopy(const Source: TATBools; SourceOffset: Integer; const Dest: TATBools; DestOffset, Count: Integer); overload;

implementation

uses
  System.Math;

function ATSar(Value, Shift: Integer): Integer;
begin
  Shift := Shift and 31;
  if Value < 0 then
    Result := not (not Value shr Shift)
  else
    Result := Value shr Shift;
end;

function ATSigned(Value: Integer; Bits: Integer): Integer;
begin
  if (Bits < 1) or (Bits > 31) then
    raise EATRACData.Create('ATRAC: invalid signed field width');
  var Sign := Cardinal(1) shl (Bits - 1);
  Result := Integer(Cardinal(Value) and (Sign * 2 - 1));
  if Cardinal(Result) and Sign <> 0 then
    Dec(Result, Int64(Sign) * 2);
end;

constructor TATBits.Create(const Data: TBytes);
begin
  inherited Create;
  if Length(Data) > 1024 * 1024 then
    raise EATRACData.Create('ATRAC: packet too large');
  FData := Data;
  FDirection := 1;
end;

function TATBits.Read(Count: Integer): Integer;
begin
  if (Count < 0) or (Count > 31) or (Count > GetBitsLeft) then
    raise EATRACData.Create('ATRAC: truncated bitstream');
  var Value: Cardinal := 0;
  for var I := 1 to Count do
  begin
    Value := (Value shl 1) or ((FData[FAnchor + FDirection * (FPosition shr 3)] shr (7 - (FPosition and 7))) and 1);
    Inc(FPosition);
  end;
  Result := Integer(Value);
end;

function TATBits.ReadBool: Boolean;
begin
  Result := Read(1) <> 0;
end;

function TATBits.Read1: Integer;
begin
  Result := Read(1);
end;

procedure TATBits.Skip(Count: Integer);
begin
  if (Int64(FPosition) + Count < 0) or (Count > GetBitsLeft) then
    raise EATRACData.Create('ATRAC: invalid bitstream seek');
  Inc(FPosition, Count);
end;

function TATBits.GetBitsLeft: Integer;
begin
  if FDirection = 1 then
    Result := (Length(FData) - FAnchor) * 8 - FPosition
  else
    Result := (FAnchor + 1) * 8 - FPosition;
end;

function TATBits.GetBytesRead: Integer;
begin
  Result := FAnchor + FDirection * ((FPosition + 7) div 8);
end;

procedure TATBits.Seek(ByteOffset: Integer);
begin
  if (ByteOffset < 0) or (ByteOffset > Length(FData)) then
    raise EATRACData.Create('ATRAC: invalid byte seek');
  FAnchor := ByteOffset;
  FPosition := 0;
end;

procedure TATBits.SetDirection(Direction: Integer);
begin
  if (Direction <> 1) and (Direction <> -1) then
    raise EATRACData.Create('ATRAC: invalid bitstream direction');
  if FPosition <> 0 then
    FAnchor := FAnchor + FDirection * ((FPosition + 7) div 8);
  FPosition := 0;
  FDirection := Direction;
end;

function TATBits.Peek(Count: Integer): Integer;
begin
  var Saved := FPosition;
  Result := Read(Count);
  FPosition := Saved;
end;

procedure TATVLC.InitSparse(const Bits, Codes, Symbols: array of Integer; Count: Integer);
begin
  if Count < 0 then
    Count := Length(Bits);
  if (Count > Length(Bits)) or (Count > Length(Codes)) or ((Length(Symbols) <> 0) and (Count > Length(Symbols))) then
    raise EATRACData.Create('ATRAC: invalid Huffman table');
  FNodes := nil;
  SetLength(FNodes, 1);
  FMaximum := 0;
  for var I := 0 to Count - 1 do
  begin
    if Bits[I] = 0 then
      Continue;
    if (Bits[I] < 1) or (Bits[I] > 24) or (Codes[I] < 0) or (Cardinal(Codes[I]) >= Cardinal(1) shl Bits[I]) then
      raise EATRACData.Create('ATRAC: invalid Huffman code');
    FMaximum := Max(FMaximum, Bits[I]);
    var Node := 0;
    for var Shift := Bits[I] - 1 downto 0 do
    begin
      if FNodes[Node].Leaf then
        raise EATRACData.Create('ATRAC: overlapping Huffman code');
      var Bit := (Codes[I] shr Shift) and 1;
      var Child := FNodes[Node].Child[Bit];
      if Child = 0 then
      begin
        Child := Length(FNodes);
        if Child > 65535 then
          raise EATRACData.Create('ATRAC: oversized Huffman tree');
        SetLength(FNodes, Child + 1);
        FNodes[Node].Child[Bit] := Child;
      end;
      Node := Child;
    end;
    if FNodes[Node].Leaf or (FNodes[Node].Child[0] <> 0) or (FNodes[Node].Child[1] <> 0) then
      raise EATRACData.Create('ATRAC: duplicate Huffman code');
    FNodes[Node].Leaf := True;
    FNodes[Node].Symbol := I;
    if Length(Symbols) <> 0 then
      FNodes[Node].Symbol := Symbols[I];
  end;
end;

function TATVLC.InitVLCSparse(NbBits, NbCodes: Integer; const Widths, Codes, Symbols: TATInts): Integer;
begin
  Bits := NbBits;
  InitSparse(Widths, Codes, Symbols, NbCodes);
  Result := 0;
end;

procedure TATVLC.InitCanonical(const Description, Symbols: array of Integer);
begin
  if Length(Description) < 3 then
    raise EATRACData.Create('ATRAC: missing canonical Huffman description');
  var Minimum := Description[0];
  var Maximum := Description[1];
  if (Minimum < 1) or (Maximum > 24) or (Minimum > Maximum) or (Length(Description) <> Maximum - Minimum + 3) then
    raise EATRACData.Create('ATRAC: invalid canonical Huffman lengths');
  var Codes, Bits: TATInts;
  var Code := 0;
  for var Width := Minimum to Maximum do
  begin
    var Count := Description[Width - Minimum + 2];
    if (Count < 0) or (Length(Codes) + Count > 4096) then
      raise EATRACData.Create('ATRAC: invalid Huffman count');
    for var I := 1 to Count do
    begin
      Bits := Bits + [Width];
      Codes := Codes + [Code];
      Inc(Code);
    end;
    Code := Code shl 1;
  end;
  InitSparse(Bits, Codes, Symbols);
end;

function TATVLC.GetVLC2(Reader: TATBits; MaxDepth: Integer): Integer;
begin
  var Node := 0;
  for var I := 1 to FMaximum do
  begin
    Node := FNodes[Node].Child[Reader.Read(1)];
    if Node = 0 then
      raise EATRACData.Create('ATRAC: invalid Huffman symbol');
    if FNodes[Node].Leaf then
      Exit(FNodes[Node].Symbol);
  end;
  raise EATRACData.Create('ATRAC: unterminated Huffman symbol');
end;

destructor TATIMDCT.Destroy;
begin
  FTransform.Free;
  inherited
end;

function TATIMDCT.MDCTInit(Bits: Integer; Inverse: Boolean; Scale: Double): Integer;
begin
  if not Inverse or (Bits < 3) or (Bits > 10) then
    raise EATRACData.Create('ATRAC: unsupported transform dimensions');
  FSize := 1 shl Bits;
  FScale := -Scale;
  FreeAndNil(FTransform);
  FTransform := TInverseMDCT.Create(FSize div 2);
  SetLength(FTransformInput, FSize div 2);
  Result := 0;
end;

{$Q-}{$R-}
procedure TATIMDCT.Transform(const Input: TATFloats; InputOffset: Integer);
begin
  if (FSize = 0) or (InputOffset < 0) or (InputOffset > Length(Input)) or
    (FSize div 2 > Length(Input) - InputOffset) then
    raise EATRACData.Create('ATRAC: invalid transform input');
  for var I := 0 to FSize div 2 - 1 do
    FTransformInput[I] := Input[InputOffset + I];
  FTransform.Execute(FTransformInput, 0, FTransformOutput);
end;

procedure TATIMDCT.IMDCTCalc(const Output: TATFloats; OutputOffset: Integer; const Input: TATFloats; InputOffset: Integer);
begin
  if (OutputOffset < 0) or (OutputOffset > Length(Output)) or (FSize > Length(Output) - OutputOffset) then
    raise EATRACData.Create('ATRAC: invalid transform output');
  Transform(Input, InputOffset);
  for var I := 0 to FSize - 1 do
    Output[OutputOffset + I] := FTransformOutput[I] * FScale;
end;

procedure TATIMDCT.IMDCTHalf(const Output: TATFloats; OutputOffset: Integer; const Input: TATFloats; InputOffset: Integer);
begin
  if (OutputOffset < 0) or (OutputOffset > Length(Output)) or (FSize div 2 > Length(Output) - OutputOffset) then
    raise EATRACData.Create('ATRAC: invalid half transform output');
  Transform(Input, InputOffset);
  for var I := 0 to FSize div 2 - 1 do
    Output[OutputOffset + I] := FTransformOutput[FSize div 4 + I] * FScale;
end;

procedure ATFill(const Data: TATInts; First, Last, Value: Integer);
begin
  for var I := First to Last - 1 do
    Data[I] := Value;
end;

procedure ATFill(const Data: TATFloats; First, Last: Integer; Value: Single);
begin
  for var I := First to Last - 1 do
    Data[I] := Value;
end;

procedure ATFill(const Data: TATBools; First, Last: Integer; Value: Boolean);
begin
  for var I := First to Last - 1 do
    Data[I] := Value;
end;

procedure ATCopy(const Source: TATInts; SourceOffset: Integer; const Dest: TATInts; DestOffset, Count: Integer);
begin
  if (SourceOffset < 0) or (DestOffset < 0) or (Count < 0) or (SourceOffset + Count > Length(Source)) or (DestOffset + Count > Length(Dest)) then
    raise EATRACData.Create('ATRAC: invalid integer copy');
  if Count > 0 then
    Move(Source[SourceOffset], Dest[DestOffset], Count * SizeOf(Integer));
end;

procedure ATCopy(const Source: TATFloats; SourceOffset: Integer; const Dest: TATFloats; DestOffset, Count: Integer);
begin
  if (SourceOffset < 0) or (DestOffset < 0) or (Count < 0) or (SourceOffset + Count > Length(Source)) or (DestOffset + Count > Length(Dest)) then
    raise EATRACData.Create('ATRAC: invalid sample copy');
  if Count > 0 then
    Move(Source[SourceOffset], Dest[DestOffset], Count * SizeOf(Single));
end;

procedure ATCopy(const Source: TATBools; SourceOffset: Integer; const Dest: TATBools; DestOffset, Count: Integer);
begin
  if (SourceOffset < 0) or (DestOffset < 0) or (Count < 0) or (SourceOffset + Count > Length(Source)) or (DestOffset + Count > Length(Dest)) then
    raise EATRACData.Create('ATRAC: invalid flag copy');
  if Count > 0 then
    Move(Source[SourceOffset], Dest[DestOffset], Count * SizeOf(Boolean));
end;

end.

