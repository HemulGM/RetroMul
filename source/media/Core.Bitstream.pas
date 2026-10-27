unit Core.Bitstream;

{
  Shared AAC/AVC bit reader and VLC tables, extracted from FMXAudio.Bitstream
  and Video.AVC.Bitstream. Upstream: FMXAudioLib and Player, supplied by the
  user; FFmpeg n7.1 derived algorithms, LGPL-2.1-or-later.
  See ../hardware/audio/codecs/ORIGIN.md and ../hardware/video/avc/NOTICE.txt.
}

interface

uses
  System.SysUtils;

type
  EBitstreamError = class(Exception);

  EBitstreamFormat = class(EBitstreamError);

  TVLCNode = record
    Child: array[0..1] of Integer;
    Symbol: Integer;
  end;

  TVLCTable = record
    Nodes: TArray<TVLCNode>;
    PrefixNode: array[0..255] of Integer;
    PrefixLength: array[0..255] of Byte;
    procedure Build(const Codes: array of Cardinal; const Lengths: array of Byte);
  end;

  TBitReader = record
  private
    FData: TBytes;
    FPosition: Integer;
    FRBSPStop: Integer;
  public
    procedure Init(const Data: TBytes);
    function ReadBits(Count: Integer): Cardinal;
    function ReadBit: Boolean; inline;
    function ReadUE: Cardinal;
    function ReadSE: Integer;
    function ReadVLC(const Codes: array of Cardinal; const Lengths: array of Byte): Integer; overload;
    function ReadVLC(const Table: TVLCTable): Integer; overload;
    procedure Skip(Count: Integer);
    procedure Align;
    procedure AppendZeroPadding(Count: Integer);
    function Remaining: Integer;
    function MoreRBSP: Boolean;
    property Position: Integer read FPosition;
  end;

function UnescapeNAL(const NAL: TBytes; AllowTrailingPreventionByte: Boolean = False): TBytes;

implementation

procedure TVLCTable.Build(const Codes: array of Cardinal; const Lengths: array of Byte);
var
  i, j, N, Used, Bit, Next: Integer;
begin
  if (Length(Codes) <> Length(Lengths)) or (Length(Codes) > 65536) then
    raise EBitstreamError.Create('Invalid VLC table');
  SetLength(Nodes, 1 + Length(Codes) * 32);
  for i := 0 to High(Nodes) do
  begin
    Nodes[i].Child[0] := -1;
    Nodes[i].Child[1] := -1;
    Nodes[i].Symbol := -1
  end;
  Used := 1;
  for i := 0 to High(Codes) do
  begin
    if Lengths[i] = 0 then
      Continue;
    if Lengths[i] > 32 then
      raise EBitstreamError.Create('Invalid VLC code length');
    N := 0;
    for j := Lengths[i] - 1 downto 0 do
    begin
      if Nodes[N].Symbol >= 0 then
        raise EBitstreamError.Create('VLC prefix collision');
      Bit := (Codes[i] shr j) and 1;
      Next := Nodes[N].Child[Bit];
      if Next < 0 then
      begin
        Next := Used;
        Inc(Used);
        Nodes[N].Child[Bit] := Next
      end;
      N := Next;
    end;
    if (Nodes[N].Symbol >= 0) or (Nodes[N].Child[0] >= 0) or (Nodes[N].Child[1] >= 0) then
      raise EBitstreamError.Create('VLC code collision');
    Nodes[N].Symbol := i;
  end;
  SetLength(Nodes, Used);
  for i := 0 to 255 do
  begin
    N := 0;
    j := 0;
    while (N >= 0) and (Nodes[N].Symbol < 0) and (j < 8) do
    begin
      N := Nodes[N].Child[(i shr (7 - j)) and 1];
      Inc(j)
    end;
    PrefixNode[i] := N;
    PrefixLength[i] := j;
  end;
end;

function TBitReader.ReadVLC(const Table: TVLCTable): Integer;
var
  N, Prefix: Integer;
begin
  if Length(Table.Nodes) = 0 then
    raise EBitstreamError.Create('Uninitialized VLC table');
  N := 0;
  if Remaining >= 8 then
  begin
    Prefix := ReadBits(8);
    N := Table.PrefixNode[Prefix];
    Dec(FPosition, 8 - Table.PrefixLength[Prefix]);
  end;
  while N >= 0 do
  begin
    if Table.Nodes[N].Symbol >= 0 then
      Exit(Table.Nodes[N].Symbol);
    N := Table.Nodes[N].Child[Ord(ReadBit)];
  end;
  raise EBitstreamFormat.Create('Invalid variable-length code');
end;

procedure TBitReader.Init(const Data: TBytes);
var
  Last, Trailing, Value: Integer;
begin
  if Length(Data) > MaxInt div 8 then
    raise EBitstreamFormat.Create('Bitstream too large');
  FData := Data;
  FPosition := 0;
  Last := Length(Data) - 1;
  while (Last >= 0) and (Data[Last] = 0) do
    Dec(Last);
  FRBSPStop := -1;
  if Last >= 0 then
  begin
    Value := Data[Last];
    Trailing := 0;
    while not Odd(Value) do
    begin
      Inc(Trailing);
      Value := Value shr 1
    end;
    FRBSPStop := Last * 8 + 7 - Trailing;
  end;
end;

function TBitReader.Remaining: Integer;
begin
  Result := Length(FData) * 8 - FPosition;
end;

function TBitReader.ReadBits(Count: Integer): Cardinal;
var
  Take, Available: Integer;
begin
  if (Count < 0) or (Count > 32) or (Count > Remaining) then
    raise EBitstreamFormat.Create('Truncated bitstream');
  Result := 0;
  // Consume byte fragments rather than branching for every input bit.
  while Count > 0 do
  begin
    Available := 8 - (FPosition and 7);
    Take := Count;
    if Take > Available then
      Take := Available;
    Result :=
      (Result shl Take) or (Cardinal(FData[FPosition shr 3] shr (Available - Take)) and ((Cardinal(1) shl Take) - 1));
    Inc(FPosition, Take);
    Dec(Count, Take);
  end;
end;

function TBitReader.ReadBit: Boolean;
begin
  if FPosition >= Length(FData) * 8 then
    raise EBitstreamFormat.Create('Truncated bitstream');
  Result := (FData[FPosition shr 3] and (128 shr (FPosition and 7))) <> 0;
  Inc(FPosition);
end;

procedure TBitReader.Skip(Count: Integer);
begin
  if (Count < 0) or (Count > Remaining) then
    raise EBitstreamFormat.Create('Truncated bitstream');
  Inc(FPosition, Count);
end;

procedure TBitReader.Align;
begin
  Skip((8 - (FPosition and 7)) and 7);
end;

procedure TBitReader.AppendZeroPadding(Count: Integer);
begin
  if (Count < 0) or (Count > 16) or (Length(FData) > MaxInt div 8 - Count) then
    raise EBitstreamFormat.Create('Invalid bitstream padding');
  // SetLength detaches shared arrays, preserving the caller's packet bytes.
  SetLength(FData, Length(FData) + Count);
end;

function TBitReader.ReadUE: Cardinal;
var
  Z: Integer;
begin
  Z := 0;
  while not ReadBit do
  begin
    Inc(Z);
    if Z > 30 then
      raise EBitstreamFormat.Create('Exp-Golomb value exceeds supported range');
  end;
  Result := ((Cardinal(1) shl Z) - 1) + ReadBits(Z);
end;

function TBitReader.ReadSE: Integer;
var
  U: Cardinal;
begin
  U := ReadUE;
  if Odd(U) then
    Result := Integer((U + 1) shr 1)
  else
    Result := -Integer(U shr 1);
end;

function TBitReader.ReadVLC(const Codes: array of Cardinal; const Lengths: array of Byte): Integer;
var
  Code: Cardinal;
  n, i, MaxLen: Integer;
begin
  if Length(Codes) <> Length(Lengths) then
    raise EBitstreamError.Create('Invalid VLC table');
  MaxLen := 0;
  for i := 0 to High(Lengths) do
    if Lengths[i] > MaxLen then
      MaxLen := Lengths[i];
  Code := 0;
  for n := 1 to MaxLen do
  begin
    Code := (Code shl 1) or ReadBits(1);
    for i := 0 to High(Lengths) do
      if (Lengths[i] = n) and (Codes[i] = Code) then
        Exit(i);
  end;
  raise EBitstreamFormat.Create('Invalid variable-length code');
end;

function TBitReader.MoreRBSP: Boolean;
begin
  // Locate rbsp_stop_one_bit once, including legal trailing zero bytes from
  // Annex B. A "remaining > 8" shortcut misreads padded PPS as extensions.
  Result := FPosition < FRBSPStop;
end;

function UnescapeNAL(const NAL: TBytes; AllowTrailingPreventionByte: Boolean): TBytes;
var
  i, N, Zeros: Integer;
begin
  SetLength(Result, Length(NAL));
  N := 0;
  Zeros := 0;
  i := 0;
  while i < Length(NAL) do
  begin
    if (Zeros >= 2) and (NAL[i] = 3) then
    begin
      // PSP CABAC zero-word tails may end in an emulation-prevention byte.
      // Other callers retain strict validation of the following byte.
      if i + 1 = Length(NAL) then
      begin
        if not AllowTrailingPreventionByte then
          raise EBitstreamFormat.Create('Invalid NAL emulation-prevention byte');
      end
      else if NAL[i + 1] > 3 then
        raise EBitstreamFormat.Create('Invalid NAL emulation-prevention byte');
      Zeros := 0;
    end
    else
    begin
      Result[N] := NAL[i];
      Inc(N);
      if NAL[i] = 0 then
        Inc(Zeros)
      else
        Zeros := 0;
    end;
    Inc(i);
  end;
  SetLength(Result, N);
end;

end.

