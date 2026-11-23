unit SWF.ScreenVideo2;

interface

uses
  System.SysUtils, Media.Image.PixelBuffer;

type
  TScreenVideoPalette = TArray<Cardinal>;

  TScreenVideo2Packet = record
    Width, Height, BlockWidth, BlockHeight, Offset: Integer;
    KeyFrame, HasIFrameImage, PrimeCurrent: Boolean;
    Palette: TScreenVideoPalette;
  end;

  TScreenVideo2State = record
    KeyBitmap: IImagePixelBuffer;
    KeyData: TBytes;
    BlockWidth, BlockHeight: Integer;
    KeyOffsets: TArray<Integer>;
  end;

function ReadScreenVideo2(const Data: TBytes; HeaderOffset: Integer; out Packet: TScreenVideo2Packet): Boolean;

procedure DecodeScreenVideo2(const Data: TBytes; const Packet: TScreenVideo2Packet; const Palette: TScreenVideoPalette; var State: TScreenVideo2State; var Bitmap: IImagePixelBuffer; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer);

implementation

uses
  System.Math, System.ZLib, SWF.Reader, SWF.Bitmap;

const
  // Adobe SWF File Format Specification v19, Appendix C, in palette order.
  DefaultPalette: array[0..127] of Cardinal = (
    $000000, $333333, $666666, $999999, $CCCCCC, $FFFFFF, $330000, $660000,
    $990000, $CC0000, $FF0000, $003300, $006600, $009900, $00CC00, $00FF00,
    $000033, $000066, $000099, $0000CC, $0000FF, $333300, $666600, $999900,
    $CCCC00, $FFFF00, $003333, $006666, $009999, $00CCCC, $00FFFF, $330033,
    $660066, $990099, $CC00CC, $FF00FF, $FFFF33, $FFFF66, $FFFF99, $FFFFCC,
    $FF33FF, $FF66FF, $FF99FF, $FFCCFF, $33FFFF, $66FFFF, $99FFFF, $CCFFFF,
    $CCCC33, $CCCC66, $CCCC99, $CCCCFF, $CC33CC, $CC66CC, $CC99CC, $CCFFCC,
    $33CCCC, $66CCCC, $99CCCC, $FFCCCC, $999933, $999966, $9999CC, $9999FF,
    $993399, $996699, $99CC99, $99FF99, $339999, $669999, $CC9999, $FF9999,
    $666633, $666699, $6666CC, $6666FF, $663366, $669966, $66CC66, $66FF66,
    $336666, $996666, $CC6666, $FF6666, $333366, $333399, $3333CC, $3333FF,
    $336633, $339933, $33CC33, $33FF33, $663333, $993333, $CC3333, $FF3333,
    $003366, $336600, $660033, $006633, $330066, $663300, $336699, $669933,
    $993366, $339966, $663399, $996633, $6699CC, $99CC66, $CC6699, $66CC99,
    $9966CC, $CC9966, $99CCFF, $CCFF99, $FF99CC, $99FFCC, $CC99FF, $FFCC99,
    $111111, $222222, $444444, $555555, $AAAAAA, $BBBBBB, $DDDDDD, $EEEEEE);

type
  TScreenBlock = record
    Offset, Size, StartRow, RowCount: Integer;
    Hybrid, Partial, PrimeCurrent, PrimePrevious: Boolean;
  end;

function ReadBE16(const Data: TBytes; Offset: Integer): Integer;
begin
  Result := (Integer(Data[Offset]) shl 8) or Data[Offset + 1];
end;

function BGR(const Data: TBytes; Offset: Integer): Cardinal;
begin
  Result := Cardinal(Data[Offset]) or (Cardinal(Data[Offset + 1]) shl 8) or
    (Cardinal(Data[Offset + 2]) shl 16);
end;

function ReadBlock(const Data: TBytes; var Offset: Integer; Height: Integer; out Block: TScreenBlock): Boolean;
var
  Size, Format, Last: Integer;
begin
  Result := False;
  Block := Default(TScreenBlock);
  if Length(Data) - Offset < 2 then
    Exit;
  Size := ReadBE16(Data, Offset);
  Inc(Offset, 2);
  if Size > Length(Data) - Offset then
    Exit;
  if Size = 0 then
    Exit(True);
  Last := Offset + Size;
  Format := Data[Offset];
  Inc(Offset);
  if (Format and $F8 <> 0) and (Format and $F8 <> $10) then
    Exit;
  Block.PrimeCurrent := Format and 2 <> 0;
  Block.Hybrid := Format and $10 <> 0;
  Block.Partial := Format and 4 <> 0;
  Block.PrimePrevious := Format and 1 <> 0;
  Block.RowCount := Height;
  if Block.Partial then
  begin
    if Last - Offset < 2 then
      Exit;
    Block.StartRow := Data[Offset];
    Block.RowCount := Data[Offset + 1];
    Inc(Offset, 2);
    if (Block.RowCount = 0) or (Block.StartRow + Block.RowCount > Height) then
      Exit;
  end;
  if Block.PrimeCurrent then
  begin
    if Last - Offset < 2 then
      Exit;
    Inc(Offset, 2);
  end;
  Block.Offset := Offset;
  Block.Size := Last - Offset;
  Offset := Last;
  Result := Block.Size > 0;
end;

function ReadScreenVideo2(const Data: TBytes; HeaderOffset: Integer; out Packet: TScreenVideo2Packet): Boolean;
var
  Horizontal, Vertical, Flags, Offset, PaletteOffset, PaletteSize, I, Image, X, Y: Integer;
  PaletteData: TBytes;
  Block: TScreenBlock;
begin
  Result := False;
  Packet := Default(TScreenVideo2Packet);
  if Length(Data) - HeaderOffset < 5 then
    Exit;
  Horizontal := ReadBE16(Data, HeaderOffset);
  Vertical := ReadBE16(Data, HeaderOffset + 2);
  Packet.Width := Horizontal and $FFF;
  Packet.Height := Vertical and $FFF;
  if (Packet.Width = 0) or (Packet.Height = 0) then
    Exit;
  Packet.BlockWidth := ((Horizontal shr 12) + 1) * 16;
  Packet.BlockHeight := ((Vertical shr 12) + 1) * 16;
  Flags := Data[HeaderOffset + 4];
  if Flags and $FC <> 0 then
    Exit;
  Packet.HasIFrameImage := Flags and 2 <> 0;
  Offset := HeaderOffset + 5;
  PaletteOffset := 0;
  PaletteSize := 0;
  if Flags and 1 <> 0 then
  begin
    if Length(Data) - Offset < 2 then
      Exit;
    PaletteSize := ReadBE16(Data, Offset);
    Inc(Offset, 2);
    if (PaletteSize = 0) or (PaletteSize > Length(Data) - Offset) then
      Exit;
    PaletteOffset := Offset;
    Inc(Offset, PaletteSize);
  end;
  Packet.KeyFrame := True;
  Packet.Offset := Offset;
  for Image := 0 to Ord(Packet.HasIFrameImage) do
  begin
    Y := 0;
    while Y < Packet.Height do
    begin
      X := 0;
      while X < Packet.Width do
      begin
        if not ReadBlock(Data, Offset, Min(Packet.BlockHeight, Packet.Height - Y), Block) then
          Exit;
        if (Block.Size = 0) or Block.Partial or Block.PrimePrevious then
          Packet.KeyFrame := False;
        Packet.PrimeCurrent := Packet.PrimeCurrent or Block.PrimeCurrent;
        Inc(X, Packet.BlockWidth);
      end;
      Inc(Y, Packet.BlockHeight);
    end;
  end;
  if Offset <> Length(Data) then
    Exit;
  if PaletteSize > 0 then
  begin
    PaletteData := InflateBitmap(Copy(Data, PaletteOffset, PaletteSize), 128 * 3);
    SetLength(Packet.Palette, 128);
    for I := 0 to High(Packet.Palette) do
      Packet.Palette[I] := BGR(PaletteData, I * 3);
  end;
  Result := True;
end;

function InflateScreenBlock(const Data: TBytes; const Block: TScreenBlock; Maximum: Integer; const History: TBytes): TBytes;
var
  Stream: z_stream;
  Input: TBytes;
  Source, Offset, Size, Complement, Count: Integer;
begin
  Count := Length(History);
  if Count = 0 then
    Input := Copy(Data, Block.Offset, Block.Size)
  else
  begin
    // Reconstruct the zlib prefix with byte-aligned DEFLATE stored blocks.
    // This restores both the sliding window and the checksum of the prefix.
    SetLength(Input, 2 + Count + 5 * ((Count + 65534) div 65535) + Block.Size);
    Input[0] := $78;
    Input[1] := $01;
    Source := 0;
    Offset := 2;
    while Source < Count do
    begin
      Size := Min(65535, Count - Source);
      Complement := Size xor $FFFF;
      Input[Offset] := 0;
      Input[Offset + 1] := Byte(Size);
      Input[Offset + 2] := Byte(Size shr 8);
      Input[Offset + 3] := Byte(Complement);
      Input[Offset + 4] := Byte(Complement shr 8);
      Inc(Offset, 5);
      Move(History[Source], Input[Offset], Size);
      Inc(Offset, Size);
      Inc(Source, Size);
    end;
    Move(Data[Block.Offset], Input[Offset], Block.Size);
  end;
  SetLength(Result, Count + Maximum + 1);
  Stream := Default(z_stream);
  if inflateInit(Stream) <> Z_OK then
    raise ESWFError.Create('Cannot initialize ScreenVideo 2 inflater');
  try
    Stream.next_in := @Input[0];
    Stream.avail_in := Length(Input);
    Stream.next_out := @Result[0];
    Stream.avail_out := Length(Result);
    if (inflate(Stream, Z_FINISH) <> Z_STREAM_END) or (Stream.avail_in <> 0) or
      (Stream.total_out <= UInt64(Count)) or (Stream.total_out > UInt64(Count + Maximum)) then
      raise ESWFError.Create('Invalid ScreenVideo 2 compressed block');
    Size := Integer(Stream.total_out) - Count;
    if Count > 0 then
      Move(Result[Count], Result[0], Size);
    SetLength(Result, Size);
  finally
    inflateEnd(Stream);
  end;
end;

function Expand5(Value: Cardinal): Cardinal;
begin
  Result := (Value shl 3) or (Value shr 2);
end;

procedure WriteBlock(const Block: TScreenBlock; const Data: TBytes; const Palette: TScreenVideoPalette; const Pixels: TArray<Cardinal>; X, Y, Width, Height, BlockWidth: Integer);
var
  Row, Column, Input, Output: Integer;
  Color, PackedColor: Cardinal;
begin
  if Block.Hybrid then
  begin
    if Length(Data) < BlockWidth * Block.RowCount then
      raise ESWFError.Create('Short ScreenVideo 2 hybrid block');
  end
  else if Length(Data) <> BlockWidth * Block.RowCount * 3 then
    raise ESWFError.Create('Invalid ScreenVideo 2 RGB block length');
  Input := 0;
  for Row := 0 to Block.RowCount - 1 do
  begin
    Output := (Height - Y - Block.StartRow - Row - 1) * Width + X;
    for Column := 0 to BlockWidth - 1 do
    begin
      if Block.Hybrid then
      begin
        if Input >= Length(Data) then
          raise ESWFError.Create('Short ScreenVideo 2 palette data');
        Color := Data[Input];
        Inc(Input);
        if Color >= 128 then
        begin
          if Input >= Length(Data) then
            raise ESWFError.Create('Short ScreenVideo 2 RGB15 color');
          PackedColor := ((Color and $7F) shl 8) or Data[Input];
          Inc(Input);
          Color := (Expand5(PackedColor shr 10) shl 16) or
            (Expand5((PackedColor shr 5) and 31) shl 8) or Expand5(PackedColor and 31);
        end
        else if Palette <> nil then
          Color := Palette[Color]
        else
          Color := DefaultPalette[Color];
      end
      else
      begin
        Color := BGR(Data, Input);
        Inc(Input, 3);
      end;
      Pixels[Output + Column] := Color or $FF000000;
    end;
  end;
  if Input <> Length(Data) then
    raise ESWFError.Create('Excess ScreenVideo 2 block data');
end;

procedure DecodeScreenVideo2(const Data: TBytes; const Packet: TScreenVideo2Packet; const Palette: TScreenVideoPalette; var State: TScreenVideo2State; var Bitmap: IImagePixelBuffer; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer);
var
  NextBitmap: IImagePixelBuffer;
  Pixels, KeyPixels: TArray<Cardinal>;
  NextOffsets: TArray<Integer>;
  Block, KeyBlock: TScreenBlock;
  Raw, History: TBytes;
  HasKey: Boolean;
  W, H, X, Y, BW, BH, Offset, Index, KeyOffset, Row, Output, Maximum: Integer;
begin
  if Length(Data) = 0 then
    Exit;
  if Packet.HasIFrameImage then
    raise ESWFError.Create('ScreenVideo 2 supplementary I-frame image is unsupported');
  if Packet.PrimeCurrent then
    raise ESWFError.Create('ScreenVideo 2 current-block zlib priming is unsupported');
  W := Packet.Width;
  H := Packet.Height;
  Inc(Work, 2 * Int64(W) * H + Length(Data));
  if Work > WorkLimit then
    raise ESWFError.Create('Flash video decoding work limit');
  if Packet.KeyFrame then
  begin
    SetLength(Pixels, W * H);
    SetLength(NextOffsets, ((W + Packet.BlockWidth - 1) div Packet.BlockWidth) *
      ((H + Packet.BlockHeight - 1) div Packet.BlockHeight));
  end
  else
  begin
    if (Bitmap = nil) or (Bitmap.Width <> W) or (Bitmap.Height <> H) then
      raise ESWFError.Create('Missing ScreenVideo 2 previous frame');
    Pixels := Copy(Bitmap.SnapshotPremultiplied);
  end;
  HasKey := not Packet.KeyFrame and (State.KeyBitmap <> nil) and
    (State.KeyBitmap.Width = W) and (State.KeyBitmap.Height = H) and
    (State.BlockWidth = Packet.BlockWidth) and (State.BlockHeight = Packet.BlockHeight);
  Offset := Packet.Offset;
  Index := 0;
  Y := 0;
  while Y < H do
  begin
    BH := Min(Packet.BlockHeight, H - Y);
    X := 0;
    while X < W do
    begin
      BW := Min(Packet.BlockWidth, W - X);
      if Packet.KeyFrame then
        NextOffsets[Index] := Offset;
      if not ReadBlock(Data, Offset, BH, Block) then
        raise ESWFError.Create('Invalid ScreenVideo 2 block');
      if Block.Size > 0 then
      begin
        if (Block.Partial or Block.PrimePrevious) and not HasKey then
          raise ESWFError.Create('Missing ScreenVideo 2 key block');
        if Block.Partial then
        begin
          if KeyPixels = nil then
            KeyPixels := State.KeyBitmap.SnapshotPremultiplied;
          for Row := 0 to BH - 1 do
          begin
            Output := (H - Y - Row - 1) * W + X;
            Move(KeyPixels[Output], Pixels[Output], BW * SizeOf(Cardinal));
          end;
        end;
        History := nil;
        if Block.PrimePrevious then
        begin
          Inc(Work, Int64(BW) * BH * 3);
          if Work > WorkLimit then
            raise ESWFError.Create('Flash video decoding work limit');
          KeyOffset := State.KeyOffsets[Index];
          if not ReadBlock(State.KeyData, KeyOffset, BH, KeyBlock) then
            raise ESWFError.Create('Invalid ScreenVideo 2 key block');
          History := InflateScreenBlock(State.KeyData, KeyBlock, BW * BH * 3, nil);
        end;
        Maximum := BW * Block.RowCount;
        if Block.Hybrid then
          Maximum := Maximum * 2
        else
          Maximum := Maximum * 3;
        Raw := InflateScreenBlock(Data, Block, Maximum, History);
        WriteBlock(Block, Raw, Palette, Pixels, X, Y, W, H, BW);
      end;
      Inc(X, BW);
      Inc(Index);
    end;
    Inc(Y, BH);
  end;
  NextBitmap := Bitmap;
  if (Bitmap = nil) or (Bitmap.Width <> W) or (Bitmap.Height <> H) or
    ((not Packet.KeyFrame) and (Bitmap = State.KeyBitmap)) then
    NextBitmap := Pool.Allocate(W, H, False, 0);
  if NextBitmap = nil then
    raise ESWFError.Create('Flash video bitmap pool limit');
  Output := 0;
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
    begin
      NextBitmap.SetPixelPremultiplied(X, Y, Pixels[Output]);
      Inc(Output);
    end;
  if Packet.KeyFrame then
  begin
    State.KeyBitmap := NextBitmap;
    State.KeyData := Data;
    State.BlockWidth := Packet.BlockWidth;
    State.BlockHeight := Packet.BlockHeight;
    State.KeyOffsets := NextOffsets;
  end;
  Bitmap := NextBitmap;
end;

end.

