unit Media.Image.PNG;

interface

uses
  System.SysUtils, System.Classes;

type
  EPNGFormat = class(Exception);

  EPNGResourceLimit = class(EPNGFormat);

  TPNGDecodeOption = (AllowTrailingData, AllowBlockPadding, AllowUnusedPaletteEntries, RecoverPaletteIndices);

  TPNGDecodeOptions = set of TPNGDecodeOption;

  TPNGImage = record
    Width, Height: Integer;
    Pixels: TArray<UInt32>; // Unpremultiplied ARGB, in PNG sample colour space.
  end;

function DecodePNG(const Data: TBytes; MaxPixels: Integer = 16 * 1024 * 1024; AllowTrailingData: Boolean = False): TPNGImage; overload;

function DecodePNG(const Data: TBytes; MaxPixels: Integer; Options: TPNGDecodeOptions): TPNGImage; overload;

procedure WritePNGRGB(Stream: TStream; Width, Height, Stride: Integer; Pixels: Pointer);

implementation

uses
  System.Math, System.ZLib;

{$Q-}{$R-}

procedure Bad(const Message: string);
begin
  raise EPNGFormat.Create(Message);
end;

function DecodePNG(const Data: TBytes; MaxPixels: Integer; AllowTrailingData: Boolean): TPNGImage;
begin
  if AllowTrailingData then
    Result := DecodePNG(Data, MaxPixels, [TPNGDecodeOption.AllowTrailingData])
  else
    Result := DecodePNG(Data, MaxPixels, []);
end;

function DecodePNG(const Data: TBytes; MaxPixels: Integer; Options: TPNGDecodeOptions): TPNGImage;
const
  StartX: array[0..6] of Integer = (0, 4, 0, 2, 0, 1, 0);
  StartY: array[0..6] of Integer = (0, 0, 4, 0, 2, 0, 1);
  StepX: array[0..6] of Integer = (8, 8, 4, 4, 2, 2, 1);
  StepY: array[0..6] of Integer = (8, 8, 8, 4, 4, 2, 2);
var
  P, Size, Body, Depth, Kind, Channels, Interlace, Passes, Pass, PW, PH, SX, SY, DX, DY: Integer;
  RowBytes, BPP, Row, Col, I, J, Filter, L, U, UL, Bit, R, G, B, A, PaletteCount, EncodedSize, At: Integer;
  AlphaGray, AlphaR, AlphaG, AlphaB: Integer;
  Name: string;
  Z: z_stream;
  Status: Integer;
  Expected: Int64;
  Compressed, Raw, Palette, Alpha, Current, Previous: TBytes;
  Samples: array[0..3] of Integer;
  Header, SeenPalette, SeenAlpha, SeenData, DataEnded, Ended: Boolean;

  function U32(Index: Integer): UInt32;
  begin
    if (Index < 0) or (Index > Length(Data) - 4) then
      Bad('Truncated PNG integer');
    Result := (UInt32(Data[Index]) shl 24) or (UInt32(Data[Index + 1]) shl 16) or (UInt32(Data[Index + 2]) shl 8) or Data[Index + 3];
  end;

  function U16(Index: Integer): Integer;
  begin
    Result := (Integer(Data[Index]) shl 8) or Data[Index + 1];
  end;

  procedure PassSize;
  begin
    SX := 0;
    SY := 0;
    DX := 1;
    DY := 1;
    if Interlace = 1 then
    begin
      SX := StartX[Pass];
      SY := StartY[Pass];
      DX := StepX[Pass];
      DY := StepY[Pass];
    end;
    PW := Max(0, (Result.Width - SX + DX - 1) div DX);
    PH := Max(0, (Result.Height - SY + DY - 1) div DY);
    RowBytes := (PW * Channels * Depth + 7) div 8;
  end;

  function Sample: Integer;
  begin
    if Depth < 8 then
      Result := (Current[Bit shr 3] shr (8 - Depth - (Bit and 7))) and ((1 shl Depth) - 1)
    else if Depth = 8 then
      Result := Current[Bit shr 3]
    else
      Result := (Integer(Current[Bit shr 3]) shl 8) or Current[(Bit shr 3) + 1];
    Inc(Bit, Depth);
  end;

  function Scale(Value: Integer): Integer;
  begin
    if Depth = 16 then
      Result := Value shr 8
    else if Depth = 8 then
      Result := Value
    else
      Result := Value * 255 div ((1 shl Depth) - 1);
  end;

  function Paeth(X, Y, Z: Integer): Integer;
  var
    PX, PY, PZ, Prediction: Integer;
  begin
    Prediction := X + Y - Z;
    PX := Abs(Prediction - X);
    PY := Abs(Prediction - Y);
    PZ := Abs(Prediction - Z);
    if (PX <= PY) and (PX <= PZ) then
      Result := X
    else if PY <= PZ then
      Result := Y
    else
      Result := Z;
  end;

begin
  Result := Default(TPNGImage);
  if (Length(Data) < 8) or (Length(Data) > 64 * 1024 * 1024) then
    Bad('PNG input size');
  if (U32(0) <> $89504E47) or (U32(4) <> $0D0A1A0A) then
    Bad('PNG signature');
  P := 8;
  Header := False;
  SeenPalette := False;
  SeenAlpha := False;
  SeenData := False;
  DataEnded := False;
  Ended := False;
  Depth := 0;
  Kind := 0;
  Channels := 0;
  Interlace := 0;
  PaletteCount := 0;
  EncodedSize := 0;
  AlphaGray := -1;
  AlphaR := -1;
  AlphaG := -1;
  AlphaB := -1;
  while P < Length(Data) do
  begin
    if Length(Data) - P < 12 then
      Bad('Truncated PNG chunk');
    if U32(P) > UInt32(Length(Data) - P - 12) then
      Bad('PNG chunk length');
    Size := Integer(U32(P));
    Body := P + 8;
    SetLength(Name, 4);
    for I := 0 to 3 do
    begin
      J := Data[P + 4 + I];
      if not ((J in [65..90]) or (J in [97..122])) then
        Bad('PNG chunk name');
      Name[I + 1] := Char(J);
    end;
    if (Data[P + 6] and $20) <> 0 then
      Bad('Reserved PNG chunk bit');
    if crc32(0, @Data[P + 4], Size + 4) <> U32(Body + Size) then
      Bad('PNG chunk CRC');
    if not Header and (Name <> 'IHDR') then
      Bad('PNG needs IHDR first');
    if SeenData and (Name <> 'IDAT') then
      DataEnded := True;
    if Name = 'IHDR' then
    begin
      if Header or (Size <> 13) then
        Bad('PNG IHDR');
      Header := True;
      if (U32(Body) = 0) or (U32(Body + 4) = 0) or (U32(Body) > UInt32(MaxInt)) or (U32(Body + 4) > UInt32(MaxInt)) then
        Bad('PNG dimensions');
      if UInt64(U32(Body)) * U32(Body + 4) > UInt64(Max(0, Min(16 * 1024 * 1024, MaxPixels))) then
        raise EPNGResourceLimit.Create('PNG dimensions exceed limit');
      Result.Width := U32(Body);
      Result.Height := U32(Body + 4);
      Depth := Data[Body + 8];
      Kind := Data[Body + 9];
      Interlace := Data[Body + 12];
      if (Data[Body + 10] <> 0) or (Data[Body + 11] <> 0) or (Interlace > 1) then
        Bad('PNG coding method');
      case Kind of
        0:
          begin
            Channels := 1;
            if not (Depth in [1, 2, 4, 8, 16]) then
              Bad('PNG gray depth');
          end;
        2:
          begin
            Channels := 3;
            if not (Depth in [8, 16]) then
              Bad('PNG RGB depth');
          end;
        3:
          begin
            Channels := 1;
            if not (Depth in [1, 2, 4, 8]) then
              Bad('PNG palette depth');
          end;
        4:
          begin
            Channels := 2;
            if not (Depth in [8, 16]) then
              Bad('PNG gray-alpha depth');
          end;
        6:
          begin
            Channels := 4;
            if not (Depth in [8, 16]) then
              Bad('PNG RGBA depth');
          end;
      else
        Bad('PNG colour type');
      end;
    end
    else if Name = 'PLTE' then
    begin
      if SeenPalette or SeenData or SeenAlpha or (Kind in [0, 4]) or (Size = 0) or (Size > 768) or (Size mod 3 <> 0) then
        Bad('PNG palette');
      PaletteCount := Size div 3;
      if (Kind = 3) and (PaletteCount > 1 shl Depth) and not (TPNGDecodeOption.AllowUnusedPaletteEntries in Options) then
        Bad('PNG palette size');
      Palette := Copy(Data, Body, Size);
      SeenPalette := True;
    end
    else if Name = 'tRNS' then
    begin
      if SeenAlpha or SeenData then
        Bad('PNG transparency order');
      SeenAlpha := True;
      case Kind of
        0:
          begin
            if Size <> 2 then
              Bad('PNG gray transparency');
            AlphaGray := U16(Body);
            if (Depth < 16) and (AlphaGray >= 1 shl Depth) then
              Bad('PNG transparency sample');
          end;
        2:
          begin
            if Size <> 6 then
              Bad('PNG RGB transparency');
            AlphaR := U16(Body);
            AlphaG := U16(Body + 2);
            AlphaB := U16(Body + 4);
            if (Depth = 8) and ((AlphaR > 255) or (AlphaG > 255) or (AlphaB > 255)) then
              Bad('PNG transparency sample');
          end;
        3:
          begin
            if not SeenPalette or (Size = 0) or (Size > PaletteCount) then
              Bad('PNG palette transparency');
            Alpha := Copy(Data, Body, Size);
          end;
      else
        Bad('PNG alpha channel already present');
      end;
    end
    else if Name = 'IDAT' then
    begin
      if DataEnded or ((Kind = 3) and not SeenPalette) then
        Bad('PNG IDAT order');
      SeenData := True;
      if EncodedSize > Length(Data) - Size then
        Bad('PNG compressed size');
      // Allocate once; copying each concatenated IDAT must not become quadratic.
      if Length(Compressed) = 0 then
        SetLength(Compressed, Length(Data));
      if Size > 0 then
        Move(Data[Body], Compressed[EncodedSize], Size);
      Inc(EncodedSize, Size);
    end
    else if Name = 'IEND' then
    begin
      if (Size <> 0) or not SeenData then
        Bad('PNG IEND');
      Ended := True;
      Inc(P, Size + 12);
      Break;
    end
    else if (Data[P + 4] and $20) = 0 then
      Bad('Unknown critical PNG chunk: ' + Name);
    Inc(P, Size + 12);
  end;
  if not Ended or (EncodedSize = 0) then
    Bad('Incomplete PNG/trailing data');
  // Some MIDlets pack standalone images into whole 1 KiB blocks. Accept
  // only the end of the final block as padding after a verified IEND.
  if (P <> Length(Data)) and not (TPNGDecodeOption.AllowTrailingData in Options) and
    (not (TPNGDecodeOption.AllowBlockPadding in Options) or (Length(Data) mod 1024 <> 0) or (Length(Data) - P >= 1024)) then
    Bad('Incomplete PNG/trailing data');
  Passes := 1;
  if Interlace = 1 then
    Passes := 7;
  Expected := 0;
  for Pass := 0 to Passes - 1 do
  begin
    PassSize;
    if (PW > 0) and (PH > 0) then
      Inc(Expected, Int64(RowBytes + 1) * PH);
  end;
  if (Expected <= 0) or (Expected > Int64(MaxPixels) * 16) or (Expected >= MaxInt) then
    raise EPNGResourceLimit.Create('PNG decoded size limit');
  SetLength(Raw, Integer(Expected) + 1);
  Z := Default(z_stream);
  if inflateInit(Z) <> Z_OK then
    Bad('Cannot initialize PNG inflater');
  try
    Z.next_in := @Compressed[0];
    Z.avail_in := EncodedSize;
    Z.next_out := @Raw[0];
    Z.avail_out := Length(Raw);
    Status := inflate(Z, Z_FINISH);
    if (Status <> Z_STREAM_END) or (Z.total_out <> UInt64(Expected)) or (Z.avail_in <> 0) then
      Bad('PNG zlib stream/decoded length');
  finally
    inflateEnd(Z);
  end;
  Compressed := nil;
  SetLength(Result.Pixels, Result.Width * Result.Height);
  At := 0;
  BPP := Max(1, (Channels * Depth + 7) div 8);
  for Pass := 0 to Passes - 1 do
  begin
    PassSize;
    if (PW = 0) or (PH = 0) then
      Continue;
    SetLength(Current, RowBytes);
    SetLength(Previous, RowBytes);
    FillChar(Previous[0], RowBytes, 0);
    for Row := 0 to PH - 1 do
    begin
      Filter := Raw[At];
      Inc(At);
      if Filter > 4 then
        Bad('PNG filter');
      for I := 0 to RowBytes - 1 do
      begin
        L := 0;
        if I >= BPP then
          L := Current[I - BPP];
        U := Previous[I];
        UL := 0;
        if I >= BPP then
          UL := Previous[I - BPP];
        J := Raw[At + I];
        case Filter of
          1:
            Inc(J, L);
          2:
            Inc(J, U);
          3:
            Inc(J, (L + U) div 2);
          4:
            Inc(J, Paeth(L, U, UL));
        end;
        Current[I] := Byte(J);
      end;
      Inc(At, RowBytes);
      Bit := 0;
      for Col := 0 to PW - 1 do
      begin
        for I := 0 to Channels - 1 do
          Samples[I] := Sample;
        R := 0;
        G := 0;
        B := 0;
        A := 255;
        case Kind of
          0, 4:
            begin
              R := Scale(Samples[0]);
              G := R;
              B := R;
              if Kind = 4 then
                A := Scale(Samples[1])
              else if Samples[0] = AlphaGray then
                A := 0;
            end;
          2, 6:
            begin
              R := Scale(Samples[0]);
              G := Scale(Samples[1]);
              B := Scale(Samples[2]);
              if Kind = 6 then
                A := Scale(Samples[3])
              else if (Samples[0] = AlphaR) and (Samples[1] = AlphaG) and (Samples[2] = AlphaB) then
                A := 0;
            end;
          3:
            begin
              J := Samples[0];
              if J < PaletteCount then
              begin
                R := Palette[J * 3];
                G := Palette[J * 3 + 1];
                B := Palette[J * 3 + 2];
                if J < Length(Alpha) then
                  A := Alpha[J];
              end
              // Missing entries retain the opaque black default specified
              // for out-of-range indices by PNG Third Edition.
              else if not (TPNGDecodeOption.RecoverPaletteIndices in Options) then
                Bad('PNG palette index');
            end;
        end;
        Result.Pixels[(SY + Row * DY) * Result.Width + SX + Col * DX] := (UInt32(A) shl 24) or (UInt32(R) shl 16) or (UInt32(G) shl 8) or UInt32(B);
      end;
      var Swap := Previous;
      Previous := Current;
      Current := Swap;
    end;
  end;
end;

procedure WritePNGRGB(Stream: TStream; Width, Height, Stride: Integer; Pixels: Pointer);
const
  Signature: array[0..7] of Byte = ($89, $50, $4E, $47, $0D, $0A, $1A, $0A);
var
  Compressed: TMemoryStream;

  procedure WriteUInt32(Value: Cardinal);
  begin
    var Bytes: array[0..3] of Byte;
    Bytes[0] := Value shr 24;
    Bytes[1] := (Value shr 16) and $FF;
    Bytes[2] := (Value shr 8) and $FF;
    Bytes[3] := Value and $FF;
    Stream.WriteBuffer(Bytes, SizeOf(Bytes));
  end;

  procedure WriteChunk(const Kind: AnsiString; const Data: TBytes);
  begin
    WriteUInt32(Length(Data));
    Stream.WriteBuffer(Kind[1], 4);
    var CRC := crc32(0, PByte(@Kind[1]), 4);
    if Length(Data) > 0 then
    begin
      Stream.WriteBuffer(Data[0], Length(Data));
      CRC := crc32(CRC, @Data[0], Length(Data));
    end;
    WriteUInt32(CRC);
  end;

begin
  if (Pixels = nil) or (Width < 1) or (Height < 1) or
    (Width > 2048) or (Height > 2048) or (Stride < Width) or
    (Int64(Stride) * Height * 4 > MaxInt) then
    raise EArgumentOutOfRangeException.Create('Invalid PNG dimensions');

  Compressed := TMemoryStream.Create;
  try
    Stream.WriteBuffer(Signature, SizeOf(Signature));
    var Header: TBytes;
    SetLength(Header, 13);
    Header[2] := (Width shr 8) and $FF;
    Header[3] := Width and $FF;
    Header[6] := (Height shr 8) and $FF;
    Header[7] := Height and $FF;
    Header[8] := 8; // Eight-bit RGB; emulator output is opaque ARGB.
    Header[9] := 2;
    WriteChunk('IHDR', Header);
    var Row: TBytes;
    SetLength(Row, 1 + Width * 3);
    Row[0] := 0; // PNG filter None.
    var Compressor := TZCompressionStream.Create(Compressed);
    try
      // Copy the host framebuffer once; all traversal uses checked array indices.
      var Source: TArray<Cardinal>;
      SetLength(Source, (Height - 1) * Stride + Width);
      Move(Pixels^, Source[0], Length(Source) * SizeOf(Cardinal));
      for var Y := 0 to Height - 1 do
      begin
        for var X := 0 to Width - 1 do
        begin
          var Color := Source[Y * Stride + X];
          Row[1 + X * 3] := (Color shr 16) and $FF;
          Row[2 + X * 3] := (Color shr 8) and $FF;
          Row[3 + X * 3] := Color and $FF;
        end;
        Compressor.WriteBuffer(Row[0], Length(Row));
      end;
    finally
      Compressor.Free;
    end;
    var Payload: TBytes;
    SetLength(Payload, Compressed.Size);
    Compressed.Position := 0;
    if Length(Payload) > 0 then
      Compressed.ReadBuffer(Payload[0], Length(Payload));
    WriteChunk('IDAT', Payload);
    WriteChunk('IEND', nil);
  finally
    Compressed.Free;
  end;
end;

end.

