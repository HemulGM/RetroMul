unit SWF.Video;

interface

uses
  System.SysUtils, System.Generics.Collections, Media.Image.PixelBuffer,
  SWF.Spark, SWF.VP6, SWF.ScreenVideo2, Video.AVC.Types;

const
  SWFSorensonSparkCodec = 2;
  SWFScreenVideoCodec = 3;
  SWFVP6Codec = 4;
  SWFVP6AlphaCodec = 5;
  SWFScreenVideo2Codec = 6;
  SWFAVCCodec = 7;
  SWFVideoPoolPixels = 32 * 1024 * 1024;

type
  TSWFAVCVideoState = record
    Decoder: IVideoDecoder;
    StartPacket, NextPacket, Request: Integer;
    Frames: TArray<TVideoFrame>;
  end;

  TSWFVideoState = record
    Bitmap: IImagePixelBuffer;
    Position: Integer;
    SparkReference: TSparkFrame;
    VP6: TVP6DecoderState;
    Screen2: TScreenVideo2State;
    AVC: TSWFAVCVideoState;
  end;

  TSWFVideoStream = class
  private
    type
      TPacket = record
        Data: TBytes;
        Offset, Width, Height, BlockWidth, BlockHeight: Integer;
        KeyFrame: Boolean;
        Spark: TSparkHeader;
        VP6: TVP6Packet;
        Screen2: TScreenVideo2Packet;
      end;
  private
    FWidth, FHeight, FFrameCount, FCodec: Integer;
    FSmooth: Boolean;
    FDeblock: Integer;
    FPackets: TDictionary<Integer, TPacket>;
    FNumbers, FKeyPositions, FPalettePositions: TArray<Integer>;
    FIndexReady: Boolean;
    procedure PrepareIndex;
    class function ReadLayout(const Data: TBytes; HeaderOffset: Integer; out Packet: TPacket): Boolean; static;
    class procedure DecodePacket(const Packet: TPacket; var State: TSWFVideoState; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer); static;
    procedure DecodeSparkPacket(const Packet: TPacket; var State: TSWFVideoState; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer);
    procedure DecodeVP6Packet(const Packet: TPacket; var State: TSWFVideoState; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer);
  protected
    function GetPacketCount: Integer; virtual;
  public
    constructor Create(AWidth, AHeight, AFrameCount, ACodec: Integer; ASmooth: Boolean; ADeblock: Integer = 0);
    destructor Destroy; override;
    procedure AddFrame(Number: Integer; const Data: TBytes; FLVFrame: Boolean = False);
    function KeyFrameBefore(Number: Integer): Integer; virtual;
    procedure Seek(Number: Integer; var State: TSWFVideoState; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer); virtual;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Codec: Integer read FCodec;
    property Smooth: Boolean read FSmooth;
    property PacketCount: Integer read GetPacketCount;
  end;

implementation

uses
  System.Math, SWF.Reader, SWF.Bitmap;

function ReadBE16(const Data: TBytes; Offset: Integer): Integer;
begin
  Result := (Integer(Data[Offset]) shl 8) or Data[Offset + 1];
end;

constructor TSWFVideoStream.Create(AWidth, AHeight, AFrameCount, ACodec: Integer; ASmooth: Boolean; ADeblock: Integer);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FFrameCount := AFrameCount;
  FCodec := ACodec;
  FSmooth := ASmooth;
  FDeblock := ADeblock;
  if FCodec in [SWFSorensonSparkCodec, SWFScreenVideoCodec, SWFVP6Codec, SWFVP6AlphaCodec,
      SWFScreenVideo2Codec] then
    FPackets := TDictionary<Integer, TPacket>.Create;
end;

destructor TSWFVideoStream.Destroy;
begin
  FPackets.Free;
  inherited;
end;

function TSWFVideoStream.GetPacketCount: Integer;
begin
  Result := 0;
  if FPackets <> nil then
    Result := FPackets.Count;
end;

class function TSWFVideoStream.ReadLayout(const Data: TBytes; HeaderOffset: Integer; out Packet: TPacket): Boolean;
var
  Horizontal, Vertical, Columns, Rows, Block, Size, Offset: Integer;
begin
  Result := False;
  Packet := Default(TPacket);
  if Length(Data) - HeaderOffset < 4 then
    Exit;
  Horizontal := ReadBE16(Data, HeaderOffset);
  Vertical := ReadBE16(Data, HeaderOffset + 2);
  Packet.Width := Horizontal and $FFF;
  Packet.Height := Vertical and $FFF;
  if (Packet.Width = 0) or (Packet.Height = 0) then
    Exit;
  Packet.BlockWidth := ((Horizontal shr 12) + 1) * 16;
  Packet.BlockHeight := ((Vertical shr 12) + 1) * 16;
  Columns := (Packet.Width + Packet.BlockWidth - 1) div Packet.BlockWidth;
  Rows := (Packet.Height + Packet.BlockHeight - 1) div Packet.BlockHeight;
  Packet.KeyFrame := True;
  Packet.Offset := HeaderOffset + 4;
  Offset := Packet.Offset;
  for Block := 1 to Columns * Rows do
  begin
    if Length(Data) - Offset < 2 then
      Exit;
    Size := ReadBE16(Data, Offset);
    Inc(Offset, 2);
    if Size > Length(Data) - Offset then
      Exit;
    if Size = 0 then
      Packet.KeyFrame := False;
    Inc(Offset, Size);
  end;
  if Offset <> Length(Data) then
    Exit;
  Packet.Data := Data;
  Result := True;
end;

procedure TSWFVideoStream.AddFrame(Number: Integer; const Data: TBytes; FLVFrame: Boolean);
var
  Packet: TPacket;
  FrameType: Integer;
begin
  if (FPackets = nil) or (Number >= FFrameCount) then
    Exit;
  if FCodec = SWFScreenVideo2Codec then
  begin
    Packet := Default(TPacket);
    if Length(Data) > 0 then
    begin
      FrameType := 0;
      if FLVFrame then
      begin
        FrameType := Data[0] shr 4;
        if (Data[0] and 15 <> SWFScreenVideo2Codec) or not (FrameType in [1, 2, 3, 4]) then
          raise ESWFError.Create('Invalid FLV ScreenVideo 2 frame type');
        if (Length(Data) > 1) and not ReadScreenVideo2(Data, 1, Packet.Screen2) then
          raise ESWFError.Create('Invalid FLV ScreenVideo 2 packet');
      end
      else if not ReadScreenVideo2(Data, 0, Packet.Screen2) then
      begin
        if not ((Data[0] in [$16, $26, $36, $46]) and ReadScreenVideo2(Data, 1, Packet.Screen2)) then
          raise ESWFError.Create('Invalid SWF ScreenVideo 2 packet');
        FrameType := Data[0] shr 4;
      end;
      if (FrameType in [1, 4]) and not (Packet.Screen2.KeyFrame or Packet.Screen2.HasIFrameImage) then
        raise ESWFError.Create('Incomplete ScreenVideo 2 keyframe');
      Packet.KeyFrame := (Packet.Screen2.KeyFrame and (FrameType in [0, 1, 4])) or Packet.Screen2.HasIFrameImage;
      Packet.Screen2.KeyFrame := Packet.KeyFrame;
      if Packet.Screen2.Width > 0 then
        Packet.Data := Data;
    end;
    FPackets.AddOrSetValue(Number, Packet);
    FIndexReady := False;
    Exit;
  end;
  if FCodec in [SWFVP6Codec, SWFVP6AlphaCodec] then
  begin
    Packet := Default(TPacket);
    Packet.VP6 := ReadVP6Packet(Data, FCodec = SWFVP6AlphaCodec, FLVFrame);
    Packet.Data := Data;
    Packet.KeyFrame := Packet.VP6.KeyFrame;
    FPackets.AddOrSetValue(Number, Packet);
    FIndexReady := False;
    Exit;
  end;
  if FCodec = SWFSorensonSparkCodec then
  begin
    Packet := Default(TPacket);
    if not ReadSparkHeader(Data, 0, Packet.Spark) and
      not ((Length(Data) > 0) and (Data[0] in [$12, $22, $32, $42]) and ReadSparkHeader(Data, 1, Packet.Spark)) then
      raise ESWFError.Create('Invalid Sorenson Spark picture header');
    Packet.Data := Data;
    Packet.KeyFrame := Packet.Spark.PictureType = 0;
    FPackets.AddOrSetValue(Number, Packet);
    FIndexReady := False;
    Exit;
  end;
  // Authoring tools can keep the FLV frame-type/codec byte in VideoFrame.
  if (Length(Data) > 0) and (Data[0] in [$13, $23]) and ReadLayout(Data, 1, Packet) then
  begin
    if (Data[0] = $13) and not Packet.KeyFrame then
      raise ESWFError.Create('Incomplete ScreenVideo keyframe');
  end
  else if not ReadLayout(Data, 0, Packet) then
    raise ESWFError.Create('Invalid ScreenVideo packet');
  FPackets.AddOrSetValue(Number, Packet);
  FIndexReady := False;
end;

procedure TSWFVideoStream.PrepareIndex;
var
  I, Keys, Palettes: Integer;
  Packet: TPacket;
begin
  if FIndexReady then
    Exit;
  FNumbers := FPackets.Keys.ToArray;
  TArray.Sort<Integer>(FNumbers);
  SetLength(FKeyPositions, Length(FNumbers));
  if FCodec = SWFScreenVideo2Codec then
    SetLength(FPalettePositions, Length(FNumbers));
  Keys := 0;
  Palettes := 0;
  for I := 0 to High(FNumbers) do
  begin
    Packet := FPackets[FNumbers[I]];
    if Packet.KeyFrame then
    begin
      FKeyPositions[Keys] := I;
      Inc(Keys);
    end;
    if Packet.Screen2.Palette <> nil then
    begin
      FPalettePositions[Palettes] := I;
      Inc(Palettes);
    end;
  end;
  SetLength(FKeyPositions, Keys);
  SetLength(FPalettePositions, Palettes);
  FIndexReady := True;
end;

function LastAtOrBefore(const Values: TArray<Integer>; Value: Integer): Integer;
var
  First, Last, Middle: Integer;
begin
  First := 0;
  Last := Length(Values);
  while First < Last do
  begin
    Middle := First + (Last - First) div 2;
    if Values[Middle] <= Value then
      First := Middle + 1
    else
      Last := Middle;
  end;
  Result := First - 1;
end;

function TSWFVideoStream.KeyFrameBefore(Number: Integer): Integer;
var
  Index: Integer;
begin
  Result := -1;
  if FPackets = nil then
    Exit;
  PrepareIndex;
  Index := LastAtOrBefore(FKeyPositions, LastAtOrBefore(FNumbers, Number));
  if Index >= 0 then
    Result := FNumbers[FKeyPositions[Index]];
end;

class procedure TSWFVideoStream.DecodePacket(const Packet: TPacket; var State: TSWFVideoState; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer);
var
  Bitmap: IImagePixelBuffer;
  Pixels: TArray<Cardinal>;
  Block: TBytes;
  SameSize: Boolean;
  W, H, Count, Offset, Size, X, Y, BW, BH, Row, Column, InputIndex, OutputIndex: Integer;
begin
  W := Packet.Width;
  H := Packet.Height;
  Count := W * H;
  Inc(Work, 2 * Int64(Count) + Length(Packet.Data));
  if Work > WorkLimit then
    raise ESWFError.Create('Flash video decoding work limit');
  SameSize := (State.Bitmap <> nil) and (State.Bitmap.Width = W) and (State.Bitmap.Height = H);
  if Packet.KeyFrame then
    SetLength(Pixels, Count)
  else
  begin
    if not SameSize then
      raise ESWFError.Create('Missing ScreenVideo reference frame');
    Pixels := Copy(State.Bitmap.SnapshotPremultiplied);
  end;
  Offset := Packet.Offset;
  Y := 0;
  while Y < H do
  begin
    BH := Min(Packet.BlockHeight, H - Y);
    X := 0;
    while X < W do
    begin
      BW := Min(Packet.BlockWidth, W - X);
      Size := ReadBE16(Packet.Data, Offset);
      Inc(Offset, 2);
      if Size > 0 then
      begin
        Block := InflateBitmap(Copy(Packet.Data, Offset, Size), BW * BH * 3);
        InputIndex := 0;
        for Row := 0 to BH - 1 do
        begin
          OutputIndex := (H - Y - Row - 1) * W + X;
          for Column := 0 to BW - 1 do
          begin
            Pixels[OutputIndex + Column] := $FF000000 or Cardinal(Block[InputIndex]) or
              (Cardinal(Block[InputIndex + 1]) shl 8) or (Cardinal(Block[InputIndex + 2]) shl 16);
            Inc(InputIndex, 3);
          end;
        end;
      end;
      Inc(Offset, Size);
      Inc(X, BW);
    end;
    Inc(Y, BH);
  end;
  // Publish the new frame only after every compressed block has been validated.
  Bitmap := State.Bitmap;
  if not SameSize then
    Bitmap := Pool.Allocate(W, H, False, 0);
  if Bitmap = nil then
    raise ESWFError.Create('Flash video bitmap pool limit');
  OutputIndex := 0;
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
    begin
      Bitmap.SetPixelPremultiplied(X, Y, Pixels[OutputIndex]);
      Inc(OutputIndex);
    end;
  State.Bitmap := Bitmap;
end;

procedure TSWFVideoStream.DecodeSparkPacket(const Packet: TPacket; var State: TSWFVideoState; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer);
var
  Frame: TSparkFrame;
  Bitmap: IImagePixelBuffer;
begin
  Frame := DecodeSpark(Packet.Data, Packet.Spark, State.SparkReference, Work, WorkLimit);
  Bitmap := State.Bitmap;
  if (Bitmap = nil) or (Bitmap.Width <> Frame.Width) or (Bitmap.Height <> Frame.Height) then
    Bitmap := Pool.Allocate(Frame.Width, Frame.Height, False, 0);
  if Bitmap = nil then
    raise ESWFError.Create('Flash video bitmap pool limit');
  PublishSpark(Frame, Packet.Spark.Quantizer, (FDeblock = 2) or
    ((FDeblock = 0) and Packet.Spark.Deblock), Bitmap);
  State.Bitmap := Bitmap;
  if Packet.Spark.PictureType <> 2 then
    State.SparkReference := Frame;
end;

procedure TSWFVideoStream.DecodeVP6Packet(const Packet: TPacket; var State: TSWFVideoState; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer);
var
  Picture: TVP6Picture;
  Next: TVP6DecoderState;
  Bitmap: IImagePixelBuffer;
  Width, Height, X, Y, Chroma, Gray, Cb, Cr, R, G, B, A: Integer;
  HasAlpha: Boolean;
begin
  if Packet.VP6.Empty then
    Exit;
  Next := State.VP6;
  Picture := DecodeVP6Frame(Packet.Data, Packet.VP6, Next, Work, WorkLimit);
  Width := Picture.Width - Packet.VP6.CropRight;
  Height := Picture.Height - Packet.VP6.CropBottom;
  if FWidth > 0 then
    Width := Min(Width, FWidth);
  if FHeight > 0 then
    Height := Min(Height, FHeight);
  if (Width <= 0) or (Height <= 0) then
    raise ESWFError.Create('Invalid VP6 display bounds');
  HasAlpha := Length(Picture.Alpha) > 0;
  Bitmap := State.Bitmap;
  if (Bitmap = nil) or (Bitmap.Width <> Width) or (Bitmap.Height <> Height) then
    Bitmap := Pool.Allocate(Width, Height, HasAlpha, 0);
  if Bitmap = nil then
    raise ESWFError.Create('Flash video bitmap pool limit');
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      Chroma := (Y div 2) * (Picture.Width div 2) + (X div 2);
      Gray := (Integer(Picture.Y[Y * Picture.Width + X]) - 16) * 76309 + 32768;
      Cb := Integer(Picture.Cb[Chroma]) - 128;
      Cr := Integer(Picture.Cr[Chroma]) - 128;
      R := EnsureRange((Gray + 104597 * Cr) div 65536, 0, 255);
      G := EnsureRange((Gray - 53279 * Cr - 25675 * Cb) div 65536, 0, 255);
      B := EnsureRange((Gray + 132201 * Cb) div 65536, 0, 255);
      A := 255;
      if HasAlpha then
        A := Picture.Alpha[Y * Picture.Width + X];
      Bitmap.SetPixelPremultiplied(X, Y, PremultiplyBitmapColor(
          (Cardinal(A) shl 24) or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B), HasAlpha));
    end;
  State.Bitmap := Bitmap;
  State.VP6 := Next;
end;

procedure TSWFVideoStream.Seek(Number: Integer; var State: TSWFVideoState; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer);
var
  Target, Key, First, I, PaletteIndex: Integer;
  Packet: TPacket;
  Palette: TScreenVideoPalette;
begin
  if (FPackets = nil) or (FFrameCount = 0) then
    Exit;
  PrepareIndex;
  Target := LastAtOrBefore(FNumbers, Number mod FFrameCount);
  Key := LastAtOrBefore(FKeyPositions, Target);
  if Key < 0 then
  begin
    State := Default(TSWFVideoState);
    Exit;
  end;
  First := FKeyPositions[Key];
  if State.Bitmap <> nil then
  begin
    if State.Position = Target then
      Exit;
    if State.Position < Target then
      First := Max(First, State.Position + 1);
  end;
  for I := First to Target do
  begin
    case FCodec of
      SWFSorensonSparkCodec:
        DecodeSparkPacket(FPackets[FNumbers[I]], State, Pool, Work, WorkLimit);
      SWFVP6Codec, SWFVP6AlphaCodec:
        DecodeVP6Packet(FPackets[FNumbers[I]], State, Pool, Work, WorkLimit);
      SWFScreenVideo2Codec:
        begin
          Packet := FPackets[FNumbers[I]];
          PaletteIndex := LastAtOrBefore(FPalettePositions, I);
          Palette := nil;
          if PaletteIndex >= 0 then
            Palette := FPackets[FNumbers[FPalettePositions[PaletteIndex]]].Screen2.Palette;
          DecodeScreenVideo2(Packet.Data, Packet.Screen2, Palette, State.Screen2, State.Bitmap, Pool, Work, WorkLimit);
        end;
    else
      DecodePacket(FPackets[FNumbers[I]], State, Pool, Work, WorkLimit);
    end;
    State.Position := I;
  end;
end;

end.

