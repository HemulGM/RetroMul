unit Video.AVC.H264.DSP;

// Scalar Delphi port/adaptation of FFmpeg H.264 CAVLC, IDCT and prediction.
// Copyright (c) 2003 Michael Niedermayer; LGPL-2.1-or-later.
// IDCT reference: Copyright (c) 2004-2011 Michael Niedermayer.
// Original files and full notices are retained in reference/.

interface

uses
  Core.Bitstream, System.SysUtils, Video.AVC.Types, Video.AVC.Bitstream;

type
  TCoeffBlock = array[0..15] of Integer;

  TCoeffBlock8 = array[0..63] of Integer;

const
  Scan4: array[0..15] of Integer = (0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15);
  Scan8: array[0..63] of Integer = (
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63);

function ASR(Value, Bits: Integer): Integer; inline;

function ClipByte(Value: Integer): Byte; inline;

function DecodeResidual(var Bits: TBitReader; NC, MaxCoeff: Integer; out Block: TCoeffBlock): Integer;

procedure Dequantize(var Block: TCoeffBlock; QP: Integer; PreserveDC: Boolean); overload;

procedure Dequantize(var Block: TCoeffBlock; QP: Integer; PreserveDC: Boolean; const Scaling: array of Byte); overload;

procedure Inverse4x4Add(var Pixels: TBytes; Stride, X, Y: Integer; const Block: TCoeffBlock);

procedure Dequantize8(var Block: TCoeffBlock8; QP: Integer); overload;

procedure Dequantize8(var Block: TCoeffBlock8; QP: Integer; const Scaling: array of Byte); overload;

procedure Inverse8x8Add(var Pixels: TBytes; Stride, X, Y: Integer; const Block: TCoeffBlock8);

procedure InverseLumaDC(var Block: TCoeffBlock; QP: Integer; ScaleDC: Integer = 16);

procedure InverseChromaDC(var Block: TCoeffBlock; QP: Integer; ScaleDC: Integer = 16);

procedure Predict4(var Pixels: TBytes; Stride, X, Y, Mode: Integer; Top, Left, TopLeft, TopRight: Boolean);

procedure Predict8(var Pixels: TBytes; Stride, X, Y, Mode: Integer; Top, Left, TopLeft, TopRight: Boolean);

procedure PredictLarge(var Pixels: TBytes; Stride, X, Y, Size, Mode: Integer; Top, Left: Boolean; Chroma: Boolean);

function ChromaQP(QP: Integer): Integer;

implementation

uses
  System.Math, Video.AVC.H264.Tables;

const
  Scan: array[0..15] of Integer = (0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15);
  QPC: array[0..51] of Byte = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
    29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39);

var
  ChromaTokenVLC: TVLCTable;
  CoeffTokenVLC: array[0..3] of TVLCTable;
  TotalZerosVLC: array[0..15] of TVLCTable;
  ChromaZerosVLC: array[0..2] of TVLCTable;
  RunVLC: array[0..6] of TVLCTable;

procedure BuildVLCTables;
var
  I: Integer;
begin
  ChromaTokenVLC.Build(chroma_dc_coeff_token_bits, chroma_dc_coeff_token_len);
  for I := 0 to High(CoeffTokenVLC) do
    CoeffTokenVLC[I].Build(coeff_token_bits[I], coeff_token_len[I]);
  for I := 0 to High(TotalZerosVLC) do
    TotalZerosVLC[I].Build(total_zeros_bits[I], total_zeros_len[I]);
  for I := 0 to High(ChromaZerosVLC) do
    ChromaZerosVLC[I].Build(chroma_dc_total_zeros_bits[I], chroma_dc_total_zeros_len[I]);
  for I := 0 to High(RunVLC) do
    RunVLC[I].Build(run_bits[I], run_len[I]);
end;

function ASR(Value, Bits: Integer): Integer;
begin
  if Value >= 0 then
    Result := Value shr Bits
  else
    Result := not ((not Value) shr Bits);
end;

function ASR64(Value: Int64; Bits: Integer): Int64; inline;
begin
  if Value >= 0 then
    Result := Value shr Bits
  else
    Result := not ((not Value) shr Bits);
end;

function ClipByte(Value: Integer): Byte;
begin
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Value;
end;

function ChromaQP(QP: Integer): Integer;
begin
  Result := QPC[EnsureRange(QP, 0, 51)]
end;

function DecodeResidual(var Bits: TBitReader; NC, MaxCoeff: Integer; out Block: TCoeffBlock): Integer;
var
  Token, Table, Trailing, I, Prefix, Suffix, SuffixSize, Code, Zeros, Run, P: Integer;
  Levels: array[0..15] of Integer;
begin
  FillChar(Block, SizeOf(Block), 0);
  if MaxCoeff = 4 then
    Token := Bits.ReadVLC(ChromaTokenVLC)
  else
  begin
    if NC < 2 then
      Table := 0
    else if NC < 4 then
      Table := 1
    else if NC < 8 then
      Table := 2
    else
      Table := 3;
    Token := Bits.ReadVLC(CoeffTokenVLC[Table]);
  end;
  Result := Token shr 2;
  Trailing := Token and 3;
  if (Result > MaxCoeff) or (Trailing > Result) then
    raise EPlayerFormat.Create('Invalid CAVLC coefficient count');
  if Result = 0 then
    Exit;
  for I := 0 to Trailing - 1 do
    if Bits.ReadBit then
      Levels[I] := -1
    else
      Levels[I] := 1;
  Suffix := Ord((Result > 10) and (Trailing < 3));
  for I := Trailing to Result - 1 do
  begin
    Prefix := 0;
    while not Bits.ReadBit do
    begin
      Inc(Prefix);
      if Prefix > 25 then
        raise EPlayerFormat.Create('CAVLC coefficient overflow');
    end;
    SuffixSize := Suffix;
    if (Prefix = 14) and (Suffix = 0) then
      SuffixSize := 4;
    if Prefix >= 15 then
      SuffixSize := Prefix - 3;
    Code := (Min(Prefix, 15) shl Suffix) + Integer(Bits.ReadBits(SuffixSize));
    if (Prefix >= 15) and (Suffix = 0) then
      Inc(Code, 15);
    if Prefix >= 16 then
      Inc(Code, (1 shl (Prefix - 3)) - 4096);
    if (I = Trailing) and (Trailing < 3) then
      Inc(Code, 2);
    if Odd(Code) then
      Levels[I] := -(Code + 1) div 2
    else
      Levels[I] := (Code + 2) div 2;
    if Abs(Levels[I]) > 32767 then
      raise EPlayerFormat.Create('CAVLC coefficient exceeds 8-bit decoder range');
    if Suffix = 0 then
      Suffix := 1;
    if (Suffix < 6) and (Abs(Levels[I]) > (3 shl (Suffix - 1))) then
      Inc(Suffix);
  end;
  Zeros := 0;
  if Result < MaxCoeff then
  begin
    if MaxCoeff = 4 then
      Zeros := Bits.ReadVLC(ChromaZerosVLC[Result - 1])
    else
      Zeros := Bits.ReadVLC(TotalZerosVLC[Result - 1]);
    if Zeros > MaxCoeff - Result then
      raise EPlayerFormat.Create('Invalid CAVLC total zeros');
  end;
  P := Zeros + Result - 1;
  for I := 0 to Result - 1 do
  begin
    if (P < 0) or (P >= MaxCoeff) then
      raise EPlayerFormat.Create('Invalid CAVLC scan position');
    if MaxCoeff = 4 then
      Block[P] := Levels[I]
    else if MaxCoeff = 15 then
      Block[Scan[P + 1]] := Levels[I]
    else
      Block[Scan[P]] := Levels[I];
    Run := 0;
    if (I < Result - 1) and (Zeros > 0) then
    begin
      Table := Min(Zeros, 7) - 1;
      Run := Bits.ReadVLC(RunVLC[Table]);
      if Run > Zeros then
        raise EPlayerFormat.Create('Invalid CAVLC run');
      Dec(Zeros, Run);
    end;
    Dec(P, Run + 1);
  end;
end;

procedure Dequantize(var Block: TCoeffBlock; QP: Integer; PreserveDC: Boolean);
var
  Scaling: array[0..15] of Byte;
begin
  FillChar(Scaling, SizeOf(Scaling), 16);
  Dequantize(Block, QP, PreserveDC, Scaling)
end;

procedure Dequantize(var Block: TCoeffBlock; QP: Integer; PreserveDC: Boolean; const Scaling: array of Byte);
var
  I, C, Start, Rem, Factor: Integer;
  Coefficients: array[0..2] of Integer;
begin
  if Length(Scaling) <> 16 then
    raise EPlayerError.Create('Invalid 4x4 scaling list size');
  Start := Ord(PreserveDC);
  Rem := QP mod 6;
  Factor := 1 shl (QP div 6);
  for I := 0 to 2 do
    Coefficients[I] := Integer(ff_h264_dequant4_coeff_init[Rem][I]) * Factor;
  for I := Start to 15 do
  begin
    if ((I and 1) = 0) and ((I and 4) = 0) then
      C := 0
    else if ((I and 1) <> 0) and ((I and 4) <> 0) then
      C := 2
    else
      C := 1;
    if Scaling[I] = 16 then
      Block[I] := Block[I] * Coefficients[C]
    else
      Block[I] := Integer(ASR64(Int64(Block[I]) * Coefficients[C] * Scaling[I] + 8, 4));
  end;
end;

procedure Inverse4x4Add(var Pixels: TBytes; Stride, X, Y: Integer; const Block: TCoeffBlock);
var
  T, O: TCoeffBlock;
  I, J, A, B, C, D, P: Integer;
begin
  for I := 0 to 3 do
  begin
    J := I * 4;
    A := Block[J] + Block[J + 2];
    B := Block[J] - Block[J + 2];
    C := ASR(Block[J + 1], 1) - Block[J + 3];
    D := Block[J + 1] + ASR(Block[J + 3], 1);
    T[J] := A + D;
    T[J + 1] := B + C;
    T[J + 2] := B - C;
    T[J + 3] := A - D;
  end;
  for I := 0 to 3 do
  begin
    A := T[I] + T[I + 8];
    B := T[I] - T[I + 8];
    C := ASR(T[I + 4], 1) - T[I + 12];
    D := T[I + 4] + ASR(T[I + 12], 1);
    O[I] := A + D;
    O[I + 4] := B + C;
    O[I + 8] := B - C;
    O[I + 12] := A - D;
  end;
  for I := 0 to 3 do
    for J := 0 to 3 do
    begin
      P := (Y + I) * Stride + X + J;
      Pixels[P] := ClipByte(Integer(Pixels[P]) + ASR(O[I * 4 + J] + 32, 6));
    end;
end;

procedure Dequantize8(var Block: TCoeffBlock8; QP: Integer);
var
  Scaling: array[0..63] of Byte;
begin
  FillChar(Scaling, SizeOf(Scaling), 16);
  Dequantize8(Block, QP, Scaling)
end;

procedure Dequantize8(var Block: TCoeffBlock8; QP: Integer; const Scaling: array of Byte);
var
  I, C, Rem, Factor: Integer;
  V: Int64;
  Coefficients: array[0..5] of Integer;
begin
  if Length(Scaling) <> 64 then
    raise EPlayerError.Create('Invalid 8x8 scaling list size');
  Rem := QP mod 6;
  Factor := 1 shl (QP div 6);
  for I := 0 to 5 do
    Coefficients[I] := Integer(ff_h264_dequant8_coeff_init[Rem][I]) * Factor;
  for I := 0 to 63 do
  begin
    C := ff_h264_dequant8_coeff_init_scan[((I shr 1) and 12) or (I and 3)];
    // Round before the inverse transform, including
    // negative levels: arithmetic (level * V * 16 * 2^(QP/6) + 32) >> 6.
    if Scaling[I] = 16 then
      Block[I] := ASR(Block[I] * Coefficients[C] + 2, 2)
    else
    begin
      V := Int64(Block[I]) * Coefficients[C] * Scaling[I];
      Block[I] := Integer(ASR64(V + 32, 6));
    end;
  end;
end;

procedure Inverse8x8Add(var Pixels: TBytes; Stride, X, Y: Integer; const Block: TCoeffBlock8);
type
  TVector = array[0..7] of Integer;
var
  T: TCoeffBlock8;
  V, O: TVector;
  I, J: Integer;

  procedure Transform(const D: TVector; out R: TVector);
  var
    A0, A1, A2, A3, A4, A5, A6, A7, B0, B1, B2, B3, B4, B5, B6, B7: Integer;
  begin
    A0 := D[0] + D[4];
    A2 := D[0] - D[4];
    A4 := ASR(D[2], 1) - D[6];
    A6 := D[2] + ASR(D[6], 1);
    B0 := A0 + A6;
    B2 := A2 + A4;
    B4 := A2 - A4;
    B6 := A0 - A6;
    A1 := -D[3] + D[5] - D[7] - ASR(D[7], 1);
    A3 := D[1] + D[7] - D[3] - ASR(D[3], 1);
    A5 := -D[1] + D[7] + D[5] + ASR(D[5], 1);
    A7 := D[3] + D[5] + D[1] + ASR(D[1], 1);
    B1 := A1 + ASR(A7, 2);
    B3 := A3 + ASR(A5, 2);
    B5 := ASR(A3, 2) - A5;
    B7 := A7 - ASR(A1, 2);
    R[0] := B0 + B7;
    R[7] := B0 - B7;
    R[1] := B2 + B5;
    R[6] := B2 - B5;
    R[2] := B4 + B3;
    R[5] := B4 - B3;
    R[3] := B6 + B1;
    R[4] := B6 - B1;
  end;

begin
  // Horizontal first, then vertical; the half/quarter shifts make the order
  // significant. FFmpeg stores transposed coefficients; ours are row-major.
  T := Block;
  Inc(T[0], 32);
  for I := 0 to 7 do
  begin
    for J := 0 to 7 do
      V[J] := T[I * 8 + J];
    Transform(V, O);
    for J := 0 to 7 do
      T[I * 8 + J] := O[J];
  end;
  for I := 0 to 7 do
  begin
    for J := 0 to 7 do
      V[J] := T[J * 8 + I];
    Transform(V, O);
    for J := 0 to 7 do
      Pixels[(Y + J) * Stride + X + I] :=
        ClipByte(Integer(Pixels[(Y + J) * Stride + X + I]) + ASR(O[J], 6));
  end;
end;

procedure InverseLumaDC(var Block: TCoeffBlock; QP: Integer; ScaleDC: Integer);
var
  T: TCoeffBlock;
  I, A, B, C, D: Integer;
  Q: Int64;
begin
  for I := 0 to 3 do
  begin
    A := Block[I * 4] + Block[I * 4 + 2];
    B := Block[I * 4] - Block[I * 4 + 2];
    C := Block[I * 4 + 1] - Block[I * 4 + 3];
    D := Block[I * 4 + 1] + Block[I * 4 + 3];
    T[I * 4] := A + D;
    T[I * 4 + 1] := B + C;
    T[I * 4 + 2] := B - C;
    T[I * 4 + 3] := A - D;
  end;
  Q := Int64(ff_h264_dequant4_coeff_init[QP mod 6][0]) * ScaleDC * (1 shl (QP div 6));
  for I := 0 to 3 do
  begin
    A := T[I] + T[I + 8];
    B := T[I] - T[I + 8];
    C := T[I + 4] - T[I + 12];
    D := T[I + 4] + T[I + 12];
    Block[I] := Integer(ASR64((A + D) * Q + 32, 6));
    Block[I + 4] := Integer(ASR64((B + C) * Q + 32, 6));
    Block[I + 8] := Integer(ASR64((B - C) * Q + 32, 6));
    Block[I + 12] := Integer(ASR64((A - D) * Q + 32, 6));
  end;
end;

procedure InverseChromaDC(var Block: TCoeffBlock; QP: Integer; ScaleDC: Integer);
var
  A, B, C, D: Integer;
  Q: Int64;
begin
  A := Block[0] + Block[1];
  B := Block[0] - Block[1];
  C := Block[2] + Block[3];
  D := Block[2] - Block[3];
  Q := Int64(ff_h264_dequant4_coeff_init[QP mod 6][0]) * ScaleDC * (1 shl (QP div 6));
  Block[0] := Integer(ASR64((A + C) * Q, 5));
  Block[1] := Integer(ASR64((B + D) * Q, 5));
  Block[2] := Integer(ASR64((A - C) * Q, 5));
  Block[3] := Integer(ASR64((B - D) * Q, 5));
end;

procedure Predict4(var Pixels: TBytes; Stride, X, Y, Mode: Integer; Top, Left, TopLeft, TopRight: Boolean);
var
  T: array[-1..7] of Integer;
  L: array[-1..7] of Integer;
  I, J, P, A, K, Z, Sum, N: Integer;

  function Edge(Index: Integer): Integer;
  begin
    if Index >= 0 then
      Result := T[Min(Index, 7)]
    else
      Result := L[Min(-Index - 2, 3)];
  end;

  function VR(CX, CY: Integer; Transpose: Boolean): Integer;
  var
    Q, M: Integer;

    function E(K: Integer): Integer;
    begin
      if Transpose then
      begin
        if K >= 0 then
          Result := L[Min(K, 3)]
        else
          Result := T[Min(-K - 2, 3)];
      end
      else
        Result := Edge(K);
    end;

  begin
    Q := 2 * CX - CY;
    if Q >= 0 then
    begin
      M := CX - (CY div 2);
      if not Odd(Q) then
        Result := (E(M - 1) + E(M) + 1) div 2
      else
        Result := (E(M - 2) + 2 * E(M - 1) + E(M) + 2) div 4;
    end
    else if Q = -1 then
      Result := (E(-2) + 2 * E(-1) + E(0) + 2) div 4
    else
      Result := (E(Q - 1) + 2 * E(Q) + E(Q + 1) + 2) div 4;
  end;

begin
  if (Mode <> 2) and
    (((Mode in [0, 3, 7]) and not Top) or ((Mode in [1, 8]) and not Left) or
    ((Mode in [4, 5, 6]) and not (Top and Left and TopLeft))) then
    raise EPlayerFormat.CreateFmt('Unavailable H.264 intra prediction neighbor: x=%d y=%d mode=%d top=%d left=%d corner=%d', [X, Y, Mode, Ord(Top), Ord(Left), Ord(TopLeft)]);
  T[-1] := 128;
  if TopLeft then
    T[-1] := Pixels[(Y - 1) * Stride + X - 1];
  L[-1] := T[-1];
  for I := 0 to 3 do
  begin
    T[I] := 128;
    L[I] := 128;
    if Top then
      T[I] := Pixels[(Y - 1) * Stride + X + I];
    if Left then
      L[I] := Pixels[(Y + I) * Stride + X - 1];
  end;
  for I := 4 to 7 do
  begin
    if TopRight then
      T[I] := Pixels[(Y - 1) * Stride + X + I]
    else
      T[I] := T[3];
    L[I] := L[3];
  end;
  Sum := 0;
  N := 0;
  if Top then
  begin
    for I := 0 to 3 do
      Inc(Sum, T[I]);
    Inc(N, 4)
  end;
  if Left then
  begin
    for I := 0 to 3 do
      Inc(Sum, L[I]);
    Inc(N, 4)
  end;
  if N = 0 then
    Sum := 128
  else
    Sum := (Sum + N div 2) div N;
  for J := 0 to 3 do
    for I := 0 to 3 do
    begin
      case Mode of
        0:
          A := T[I];
        1:
          A := L[J];
        2:
          A := Sum;
        3:
          begin
            K := I + J;
            A := (T[K] + 2 * T[K + 1] + T[Min(K + 2, 7)] + 2) div 4
          end;
        4:
          begin
            K := I - J;
            A := (Edge(K - 2) + 2 * Edge(K - 1) + Edge(K) + 2) div 4
          end;
        5:
          A := VR(I, J, False);
        6:
          A := VR(J, I, True);
        7:
          begin
            K := I + J div 2;
            if Odd(J) then
              A := (T[K] + 2 * T[K + 1] + T[K + 2] + 2) div 4
            else
              A := (T[K] + T[K + 1] + 1) div 2
          end;
        8:
          begin
            Z := 2 * J + I;
            K := Min(Z div 2, 3);
            if Odd(Z) then
              A := (L[K] + 2 * L[Min(K + 1, 3)] + L[Min(K + 2, 3)] + 2) div 4
            else
              A := (L[K] + L[Min(K + 1, 3)] + 1) div 2
          end;
      else
        raise EPlayerFormat.Create('Invalid intra4x4 mode');
      end;
      P := (Y + J) * Stride + X + I;
      Pixels[P] := A;
    end;
end;

procedure Predict8(var Pixels: TBytes; Stride, X, Y, Mode: Integer; Top, Left, TopLeft, TopRight: Boolean);
var
  T, L, RawT, RawL: array[-1..15] of Integer;
  I, J, A, K, Z, Sum, N: Integer;

  function Edge(Index: Integer; Transpose: Boolean = False): Integer;
  begin
    if Transpose then
    begin
      if Index >= 0 then
        Result := L[Min(Index, 7)]
      else
        Result := T[Min(-Index - 2, 7)];
    end
    else if Index >= 0 then
      Result := T[Min(Index, 15)]
    else
      Result := L[Min(-Index - 2, 7)];
  end;

  function VR(CX, CY: Integer; Transpose: Boolean): Integer;
  var
    Q, M: Integer;
  begin
    Q := 2 * CX - CY;
    if Q >= 0 then
    begin
      M := CX - CY div 2;
      if not Odd(Q) then
        Result := (Edge(M - 1, Transpose) + Edge(M, Transpose) + 1) div 2
      else
        Result := (Edge(M - 2, Transpose) + 2 * Edge(M - 1, Transpose) + Edge(M, Transpose) + 2) div 4;
    end
    else if Q = -1 then
      Result := (Edge(-2, Transpose) + 2 * Edge(-1, Transpose) + Edge(0, Transpose) + 2) div 4
    else
      Result := (Edge(Q - 1, Transpose) + 2 * Edge(Q, Transpose) + Edge(Q + 1, Transpose) + 2) div 4;
  end;

begin
  if (Mode <> 2) and
    (((Mode in [0, 3, 7]) and not Top) or ((Mode in [1, 8]) and not Left) or
    ((Mode in [4, 5, 6]) and not (Top and Left and TopLeft))) then
    raise EPlayerFormat.Create('Unavailable H.264 intra8x8 prediction neighbor');
  RawT[-1] := 128;
  if TopLeft then
    RawT[-1] := Pixels[(Y - 1) * Stride + X - 1];
  RawL[-1] := RawT[-1];
  for I := 0 to 7 do
  begin
    RawT[I] := 128;
    RawL[I] := 128;
    if Top then
      RawT[I] := Pixels[(Y - 1) * Stride + X + I];
    if Left then
      RawL[I] := Pixels[(Y + I) * Stride + X - 1];
  end;
  for I := 8 to 15 do
  begin
    RawT[I] := RawT[7];
    if TopRight then
      RawT[I] := Pixels[(Y - 1) * Stride + X + I];
    RawL[I] := RawL[7];
  end;
  // Filter available reference samples before applying the nine directional
  // predictors (8.3.2.2). Missing top-right samples retain raw top[7].
  T[-1] := (RawL[0] + 2 * RawT[-1] + RawT[0] + 2) div 4;
  L[-1] := T[-1];
  if not TopLeft then
  begin
    RawT[-1] := RawT[0];
    RawL[-1] := RawL[0]
  end;
  for I := 0 to 7 do
  begin
    T[I] := (RawT[I - 1] + 2 * RawT[I] + RawT[I + 1] + 2) div 4;
    L[I] := (RawL[I - 1] + 2 * RawL[I] + RawL[Min(I + 1, 7)] + 2) div 4;
  end;
  for I := 8 to 15 do
    if TopRight then
      T[I] := (RawT[I - 1] + 2 * RawT[I] + RawT[Min(I + 1, 15)] + 2) div 4
    else
      T[I] := RawT[7];
  Sum := 0;
  N := 0;
  if Top then
  begin
    for I := 0 to 7 do
      Inc(Sum, T[I]);
    Inc(N, 8)
  end;
  if Left then
  begin
    for I := 0 to 7 do
      Inc(Sum, L[I]);
    Inc(N, 8)
  end;
  if N = 0 then
    Sum := 128
  else
    Sum := (Sum + N div 2) div N;
  for J := 0 to 7 do
    for I := 0 to 7 do
    begin
      case Mode of
        0:
          A := T[I];
        1:
          A := L[J];
        2:
          A := Sum;
        3:
          begin
            K := I + J;
            A := (T[K] + 2 * T[K + 1] + T[Min(K + 2, 15)] + 2) div 4
          end;
        4:
          begin
            K := I - J;
            A := (Edge(K - 2) + 2 * Edge(K - 1) + Edge(K) + 2) div 4
          end;
        5:
          A := VR(I, J, False);
        6:
          A := VR(J, I, True);
        7:
          begin
            K := I + J div 2;
            if Odd(J) then
              A := (T[K] + 2 * T[K + 1] + T[K + 2] + 2) div 4
            else
              A := (T[K] + T[K + 1] + 1) div 2
          end;
        8:
          begin
            Z := 2 * J + I;
            K := Min(Z div 2, 7);
            if Odd(Z) then
              A := (L[K] + 2 * L[Min(K + 1, 7)] + L[Min(K + 2, 7)] + 2) div 4
            else
              A := (L[K] + L[Min(K + 1, 7)] + 1) div 2
          end;
      else
        raise EPlayerFormat.Create('Invalid intra8x8 mode');
      end;
      Pixels[(Y + J) * Stride + X + I] := A;
    end;
end;

procedure PredictLarge(var Pixels: TBytes; Stride, X, Y, Size, Mode: Integer; Top, Left: Boolean; Chroma: Boolean);
var
  T, L: array[-1..15] of Integer;
  I, J, Sum, N, A, H, V, B, C, Mid, BX, BY, TS, LS: Integer;
begin
  // Public luma modes: vertical, horizontal, DC, plane. Chroma: DC, horizontal, vertical, plane.
  if Chroma then
  begin
    if Mode = 0 then
      Mode := 2
    else if Mode = 2 then
      Mode := 0;
  end;
  if ((Mode = 0) and not Top) or ((Mode = 1) and not Left) or ((Mode = 3) and not (Top and Left)) then
    raise EPlayerFormat.Create('Unavailable H.264 prediction neighbor');
  T[-1] := 128;
  if Top and Left then
    T[-1] := Pixels[(Y - 1) * Stride + X - 1];
  L[-1] := T[-1];
  Sum := 0;
  N := 0;
  for I := 0 to Size - 1 do
  begin
    T[I] := 128;
    L[I] := 128;
    if Top then
    begin
      T[I] := Pixels[(Y - 1) * Stride + X + I];
      Inc(Sum, T[I]);
      Inc(N)
    end;
    if Left then
    begin
      L[I] := Pixels[(Y + I) * Stride + X - 1];
      Inc(Sum, L[I]);
      Inc(N)
    end;
  end;
  if N = 0 then
    Sum := 128
  else
    Sum := (Sum + N div 2) div N;
  H := 0;
  V := 0;
  Mid := Size div 2 - 1;
  if Mode = 3 then
  begin
    for I := 1 to Size div 2 do
    begin
      Inc(H, I * (T[Mid + I] - T[Mid - I]));
      Inc(V, I * (L[Mid + I] - L[Mid - I]))
    end;
    if Size = 16 then
    begin
      B := ASR(5 * H + 32, 6);
      C := ASR(5 * V + 32, 6)
    end
    else
    begin
      B := ASR(17 * H + 16, 5);
      C := ASR(17 * V + 16, 5)
    end;
  end
  else
  begin
    B := 0;
    C := 0
  end;
  for J := 0 to Size - 1 do
    for I := 0 to Size - 1 do
    begin
      case Mode of
        0:
          A := T[I];
        1:
          A := L[J];
        2:
          begin
            A := Sum;
            if Chroma then
            begin
              BX := I div 4;
              BY := J div 4;
              TS := 0;
              LS := 0;
              if Top then
                for N := BX * 4 to BX * 4 + 3 do
                  Inc(TS, T[N]);
              if Left then
                for N := BY * 4 to BY * 4 + 3 do
                  Inc(LS, L[N]);
              if Top and Left then
              begin
                if BX = BY then
                  A := (TS + LS + 4) div 8
                else if BY = 0 then
                  A := (TS + 2) div 4
                else
                  A := (LS + 2) div 4;
              end
              else if Top then
                A := (TS + 2) div 4
              else if Left then
                A := (LS + 2) div 4;
            end;
          end;
        3:
          A := ClipByte(ASR(16 * (T[Size - 1] + L[Size - 1]) + B * (I - Mid) + C * (J - Mid) + 16, 5));
      else
        raise EPlayerFormat.Create('Invalid intra prediction mode');
      end;
      Pixels[(Y + J) * Stride + X + I] := A;
    end;
end;

initialization
  BuildVLCTables;

end.

