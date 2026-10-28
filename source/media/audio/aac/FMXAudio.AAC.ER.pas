unit FMXAudio.AAC.ER;

// ISO/IEC 14496-3 ER syntax, RVLC (Tables 4.166/4.168) and HCR.
// HCR schedule and normative tables studied in MIT OxideAV/oxideav-aac.
// Copyright (c) 2026 Karpeles Lab Inc.; see Licenses/OxideAAC-MIT.txt.

interface

uses
  Core.Bitstream, FMXAudio.Bitstream;

type
  TAACRVLCInfo = record
    LengthSF, LengthEscapes, ReverseGain, NoiseSeed, NoiseLast: Integer;
    NoiseUsed, EscapesPresent, Concealment: Boolean;
  end;

procedure AACReadRVLCHeader(var Bits: TBitReader; const Books: array of Integer; Count: Integer; ShortWindows: Boolean; out Info: TAACRVLCInfo);

procedure AACReadRVLCData(var Bits: TBitReader; const Info: TAACRVLCInfo; const Books: array of Integer; Count, Gain: Integer; var Scales: array of Integer);

procedure AACReadHCR(var Bits: TBitReader; LengthBits, Longest, FrameLength, Groups, MaxSFB, WindowLength: Integer; const GroupLength, Books: array of Integer; const Offsets: array of Word; const Tables: array of TVLCTable; var Quantized: array of Integer);

implementation

uses
  System.SysUtils, System.Math, FMXAudio.Types;

// RVLC TABLES BEGIN
const
  RVLC_CODES: array[0..14] of Cardinal = (65, 257, 129, 33, 17, 9, 5, 0, 7, 27, 51, 107, 195, 427, 99);
  RVLC_LENGTHS: array[0..14] of Byte = (7, 9, 8, 6, 5, 4, 3, 1, 3, 5, 6, 7, 8, 9, 7);
  RVLC_ESCAPE_CODES: array[0..53] of Cardinal = (
    2,
    0,
    6,
    2,
    14,
    31,
    15,
    13,
    61,
    29,
    25,
    24,
    120,
    56,
    242,
    114,
    486,
    230,
    974,
    463,
    1950,
    1951,
    925,
    1848,
    7399,
    3698,
    14797,
    473482,
    473483,
    473484,
    473485,
    473486,
    473487,
    473488,
    473489,
    473490,
    473491,
    473492,
    473493,
    473494,
    473495,
    473496,
    473497,
    473498,
    473499,
    473500,
    473501,
    473502,
    473503,
    236736,
    236737,
    236738,
    236739,
    236740
  );
  RVLC_ESCAPE_LENGTHS: array[0..53] of Byte = (
    2,
    2,
    3,
    3,
    4,
    5,
    5,
    5,
    6,
    6,
    6,
    6,
    7,
    7,
    8,
    8,
    9,
    9,
    10,
    10,
    11,
    11,
    11,
    12,
    14,
    13,
    15,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    20,
    19,
    19,
    19,
    19,
    19
  );
// RVLC TABLES END

function SliceBits(var Bits: TBitReader; Count: Integer): TBitReader;
var
  Data: TBytes;
begin
  if (Count < 0) or (Count > Bits.Remaining) then
    raise EPlayerFormat.Create('Truncated AAC ER payload');
  SetLength(Data, (Count + 7) div 8);
  for var i := 0 to Count - 1 do
    if Bits.ReadBit then
      Data[i div 8] := Data[i div 8] or ($80 shr (i mod 8));
  Result.Init(Data);
end;

procedure AACReadRVLCHeader(var Bits: TBitReader; const Books: array of Integer; Count: Integer; ShortWindows: Boolean; out Info: TAACRVLCInfo);
begin
  Info := Default(TAACRVLCInfo);
  Info.Concealment := Bits.ReadBit;
  Info.ReverseGain := Bits.ReadBits(8);
  if ShortWindows then
    Info.LengthSF := Bits.ReadBits(11)
  else
    Info.LengthSF := Bits.ReadBits(9);
  for var i := 0 to Count - 1 do
    Info.NoiseUsed := Info.NoiseUsed or (Books[i] = 13);
  if Info.NoiseUsed then
  begin
    Info.NoiseSeed := Bits.ReadBits(9);
    Dec(Info.LengthSF, 9);
    if Info.LengthSF < 0 then
      raise EPlayerFormat.Create('Invalid AAC RVLC length');
  end;
  Info.EscapesPresent := Bits.ReadBit;
  if Info.EscapesPresent then
    Info.LengthEscapes := Bits.ReadBits(8);
  if Info.NoiseUsed then
    Info.NoiseLast := Bits.ReadBits(9);
end;

procedure AACReadRVLCData(var Bits: TBitReader; const Info: TAACRVLCInfo; const Books: array of Integer; Count, Gain: Integer; var Scales: array of Integer);
var
  SF, Escapes: TBitReader;
  Offset, Noise, Intensity, Delta, LastIntensity: Integer;
  NoiseFirst, IntensityUsed, SpectrumUsed: Boolean;

  function ReadDelta: Integer;
  begin
    Result := SF.ReadVLC(RVLC_CODES, RVLC_LENGTHS) - 7;
    if SF.Position > Info.LengthSF then
      raise EPlayerFormat.Create('Truncated AAC RVLC data');
    if Abs(Result) = 7 then
    begin
      if not Info.EscapesPresent then
        raise EPlayerFormat.Create('Missing AAC RVLC escape');
      Delta := Escapes.ReadVLC(RVLC_ESCAPE_CODES, RVLC_ESCAPE_LENGTHS);
      if Escapes.Position > Info.LengthEscapes then
        raise EPlayerFormat.Create('Truncated AAC RVLC escape');
      if Result < 0 then
        Dec(Result, Delta)
      else
        Inc(Result, Delta);
    end;
  end;

begin
  SF := SliceBits(Bits, Info.LengthSF);
  Escapes := SliceBits(Bits, Info.LengthEscapes);
  Offset := Gain;
  Noise := Gain - 90;
  Intensity := 0;
  NoiseFirst := True;
  IntensityUsed := False;
  SpectrumUsed := False;
  for var i := 0 to Count - 1 do
    case Books[i] of
      0:
        Scales[i] := 0;
      13:
        begin
          if NoiseFirst then
            Inc(Noise, Info.NoiseSeed - 256)
          else
            Inc(Noise, ReadDelta);
          NoiseFirst := False;
          Scales[i] := EnsureRange(Noise, -100, 155);
        end;
      14, 15:
        begin
          Inc(Intensity, ReadDelta);
          IntensityUsed := True;
          Scales[i] := EnsureRange(Intensity, -155, 100);
        end;
    else
      SpectrumUsed := True;
      Inc(Offset, ReadDelta);
      if (Offset < 0) or (Offset > 255) then
        raise EPlayerFormat.Create('AAC RVLC scalefactor range');
      Scales[i] := Offset - 100;
    end;
  if IntensityUsed then
  begin
    LastIntensity := ReadDelta;
    if LastIntensity <> Intensity then
      raise EPlayerFormat.Create('AAC RVLC reverse intensity mismatch');
  end;
  if SpectrumUsed and (Offset <> Info.ReverseGain) then
    raise EPlayerFormat.Create('AAC RVLC reverse gain mismatch');
  if (SF.Position <> Info.LengthSF) or (Escapes.Position <> Info.LengthEscapes) then
    raise EPlayerFormat.Create('AAC RVLC payload length mismatch');
end;

procedure AACReadHCR(var Bits: TBitReader; LengthBits, Longest, FrameLength, Groups, MaxSFB, WindowLength: Integer; const GroupLength, Books: array of Integer; const Offsets: array of Word; const Tables: array of TVLCTable; var Quantized: array of Integer);
const
  PRIORITY: array[0..31] of Integer =
    (0, 21, 21, 20, 20, 19, 19, 18, 18, 17, 17, 0, 0, 0, 0, 0, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1);
  MAX_LENGTH: array[0..31] of Integer = (
    0,
    11,
    9,
    20,
    16,
    13,
    11,
    14,
    12,
    17,
    14,
    49,
    0,
    0,
    0,
    0,
    14,
    17,
    21,
    21,
    25,
    25,
    29,
    29,
    29,
    29,
    33,
    33,
    33,
    37,
    37,
    41
  );
type
  TCodeword = record
    Book, Destination, Dimension, Key: Integer;
    Data: TArray<Boolean>;
    Done: Boolean;
  end;

  TSegment = record
    Start, Width, Low, High: Integer;
  end;

  PCodeword = ^TCodeword;

  PSegment = ^TSegment;
var
  Codewords: TArray<TCodeword>;
  Segments: TArray<TSegment>;
  Payload: TArray<Boolean>;
  WindowBase, Count, Book, Dimension, Used, Width, SegmentCount: Integer;

  function TryDecode(var CW: TCodeword; out Consumed: Integer; out Values: TArray<Integer>): Boolean;
  var
    Position, Node, Code, Radix, Bias, Index, Value, Escape, DecodeBook: Integer;

    function Bit(out B: Integer): Boolean;
    begin
      Result := Position < Length(CW.Data);
      if Result then
      begin
        B := Ord(CW.Data[Position]);
        Inc(Position);
      end;
    end;

  begin
    Result := False;
    Position := 0;
    Node := 0;
    DecodeBook := Min(CW.Book, 11);
    while Tables[DecodeBook].Nodes[Node].Symbol < 0 do
    begin
      if not Bit(Value) then
        Exit;
      Node := Tables[DecodeBook].Nodes[Node].Child[Value];
      if Node < 0 then
        raise EPlayerFormat.Create('Invalid AAC HCR codeword');
    end;
    Code := Tables[DecodeBook].Nodes[Node].Symbol;
    Radix := 17;
    Bias := 0;
    if DecodeBook <= 4 then
    begin
      Radix := 3;
      if DecodeBook <= 2 then
        Bias := 1;
    end
    else if DecodeBook <= 6 then
    begin
      Radix := 9;
      Bias := 4;
    end
    else if DecodeBook <= 8 then
      Radix := 8
    else if DecodeBook <= 10 then
      Radix := 13;
    SetLength(Values, CW.Dimension);
    for var i := CW.Dimension - 1 downto 0 do
    begin
      Values[i] := Code mod Radix - Bias;
      Code := Code div Radix;
    end;
    if Bias = 0 then
      for var i := 0 to CW.Dimension - 1 do
        if Values[i] <> 0 then
        begin
          if not Bit(Value) then
            Exit;
          if Value <> 0 then
            Values[i] := -Values[i];
        end;
    if DecodeBook = 11 then
      for var i := 0 to CW.Dimension - 1 do
        if Abs(Values[i]) = 16 then
        begin
          Escape := 4;
          repeat
            if not Bit(Value) then
              Exit;
            if Value = 0 then
              Break;
            Inc(Escape);
            if Escape > 12 then
              raise EPlayerFormat.Create('AAC HCR escape range');
          until False;
          Index := 1;
          for var j := 1 to Escape do
          begin
            if not Bit(Value) then
              Exit;
            Index := Index * 2 + Value;
          end;
          if Values[i] < 0 then
            Index := -Index;
          Values[i] := Index;
        end;
    Consumed := Position;
    Result := True;
  end;

  procedure Feed(CWIndex, SegmentIndex: Integer; Reverse: Boolean);
  var
    Fresh, Previous, Consumed, local: Integer;
    Values: TArray<Integer>;
  begin
    var CW: PCodeword := @Codewords[CWIndex];
    var Segment: PSegment := @Segments[SegmentIndex];
    if CW.Done then
      Exit;
    Fresh := Segment.Width - Segment.Low - Segment.High;
    if Fresh = 0 then
      Exit;
    Previous := Length(CW.Data);
    SetLength(CW.Data, Previous + Fresh);
    for var i := 0 to Fresh - 1 do
    begin
      if Reverse then
        local := Segment.Width - Segment.High - 1 - i
      else
        local := Segment.Low + i;
      CW.Data[Previous + i] := Payload[Segment.Start + local];
    end;
    Consumed := Fresh + Previous;
    if TryDecode(CW^, Consumed, Values) then
    begin
      if Consumed < Previous then
        raise EPlayerFormat.Create('AAC HCR cursor mismatch');
      for var i := 0 to CW.Dimension - 1 do
        Quantized[CW.Destination + i] := Values[i];
      CW.Done := True;
      SetLength(CW.Data, 0);
    end;
    if Reverse then
      Inc(Segment.High, Consumed - Previous)
    else
      Inc(Segment.Low, Consumed - Previous);
  end;

begin
  if (LengthBits < 0) or (LengthBits > 12288) or (LengthBits > Bits.Remaining) then
    raise EPlayerFormat.Create('Invalid AAC HCR length');
  Longest := Min(Longest, 49);
  for var i := 0 to High(Quantized) do
    Quantized[i] := 0;
  WindowBase := 0;
  for var g := 0 to Groups - 1 do
  begin
    for var B := 0 to MaxSFB - 1 do
    begin
      Book := Books[g * MaxSFB + B];
      if (Book = 0) or (Book in [13, 14, 15]) then
        Continue;
      if (Book < 1) or (Book = 12) or (Book > 31) then
        raise EPlayerFormat.Create('Invalid AAC HCR codebook');
      if Book <= 4 then
        Dimension := 4
      else
        Dimension := 2;
      for var w := 0 to GroupLength[g] - 1 do
      begin
        var Line := Integer(Offsets[B]);
        while Line < Offsets[B + 1] do
        begin
          if Line + Dimension > Offsets[B + 1] then
            raise EPlayerFormat.Create('AAC HCR tuple crosses band');
          Count := Length(Codewords);
          SetLength(Codewords, Count + 1);
          Codewords[Count].Book := Book;
          Codewords[Count].Dimension := Dimension;
          Codewords[Count].Destination := (WindowBase + w) * WindowLength + Line;
          Codewords[Count].Key :=
            (PRIORITY[Book] * WindowLength + (Line and not 3)) * (FrameLength div WindowLength) + WindowBase + w;
          Inc(Line, Dimension);
        end;
      end;
    end;
    Inc(WindowBase, GroupLength[g]);
  end;
  // Stable insertion sort preserves the two tuples within each four-line unit.
  for var i := 1 to High(Codewords) do
  begin
    var CW := Codewords[i];
    var j := i;
    while (j > 0) and (Codewords[j - 1].Key > CW.Key) do
    begin
      Codewords[j] := Codewords[j - 1];
      Dec(j);
    end;
    Codewords[j] := CW;
  end;
  SetLength(Payload, LengthBits);
  for var i := 0 to LengthBits - 1 do
    Payload[i] := Bits.ReadBit;
  if Length(Codewords) = 0 then
  begin
    if LengthBits <> 0 then
      raise EPlayerFormat.Create('Unexpected AAC HCR payload');
    Exit;
  end;
  if (Longest = 0) or (LengthBits = 0) then
    raise EPlayerFormat.Create('Missing AAC HCR payload');
  Used := 0;
  for var i := 0 to High(Codewords) do
  begin
    Width := Min(MAX_LENGTH[Codewords[i].Book], Longest);
    if Used + Width > LengthBits then
      Break;
    Count := Length(Segments);
    SetLength(Segments, Count + 1);
    Segments[Count].Start := Used;
    Segments[Count].Width := Width;
    Inc(Used, Width);
  end;
  if Length(Segments) = 0 then
    SetLength(Segments, 1);
  Inc(Segments[High(Segments)].Width, LengthBits - Used);
  SegmentCount := Length(Segments);
  for var i := 0 to SegmentCount - 1 do
  begin
    Feed(i, i, False);
    if not Codewords[i].Done then
      raise EPlayerFormat.Create('Incomplete AAC HCR priority codeword');
  end;
  for var SetIndex := 1 to (Length(Codewords) + SegmentCount - 1) div SegmentCount - 1 do
    for var Trial := 0 to SegmentCount - 1 do
      for var Base := 0 to SegmentCount - 1 do
      begin
        var CWIndex := Base + SetIndex * SegmentCount;
        if CWIndex < Length(Codewords) then
          Feed(CWIndex, (Trial + Base) mod SegmentCount, Odd(SetIndex));
      end;
  for var CW in Codewords do
    if not CW.Done then
      raise EPlayerFormat.Create('Incomplete AAC HCR codeword set');
end;

end.

