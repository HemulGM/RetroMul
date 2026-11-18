unit SWF.FLV.AVC;

interface

uses
  System.SysUtils, System.Generics.Collections, Media.Image.PixelBuffer,
  Video.AVC.Types, SWF.Video;

type
  TFLVAVCStream = class(TSWFVideoStream)
  private
    type
      TAccessUnit = record
        Data: TBytes;
        Time: Int64;
        ConfigIndex, KeyIndex, Presentation, CodedPixels: Integer;
      end;

      TPresentation = record
        Time: Int64;
        DecodeIndex: Integer;
      end;
  private
    FConfigurations: TList<TBytes>;
    FPackets: TList<TAccessUnit>;
    FPresentation: TArray<TPresentation>;
    FNALLength, FCodedPixels, FLastKey: Integer;
    FMemory, FLastDecodeTime: Int64;
    procedure ReadSequence(const NAL: TBytes);
  protected
    function GetPacketCount: Integer; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddConfiguration(const Config: TBytes);
    procedure AddAccessUnit(const Data: TBytes; DecodeTime, PresentationTime: Int64);
    procedure Finish(out Times: TArray<Int64>);
    function KeyFrameBefore(Number: Integer): Integer; override;
    procedure Seek(Number: Integer; var State: TSWFVideoState; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer); override;
    property MemorySize: Int64 read FMemory;
  end;

implementation

uses
  System.Math, System.Generics.Defaults, Video.AVC.H264, Video.AVC.H264.Syntax,
  Video.AVC.Bitstream, SWF.Reader;

const
  AVCPictureLimit = 8 * 1024 * 1024;
  AVCCacheBytes = 16 * 1024 * 1024;

constructor TFLVAVCStream.Create;
begin
  inherited Create(0, 0, 0, SWFAVCCodec, True);
  FConfigurations := TList<TBytes>.Create;
  FPackets := TList<TAccessUnit>.Create;
  FLastKey := -1;
end;

destructor TFLVAVCStream.Destroy;
begin
  FPackets.Free;
  FConfigurations.Free;
  inherited;
end;

function TFLVAVCStream.GetPacketCount: Integer;
begin
  Result := Length(FPresentation);
end;

procedure TFLVAVCStream.ReadSequence(const NAL: TBytes);
var
  SPS: TH264SPS;
  CodedPixels: Integer;
begin
  ParseSPS(UnescapeNAL(Copy(NAL, 1, Length(NAL) - 1)), SPS);
  CodedPixels := SPS.MBWidth * SPS.MBHeight * 256 * (2 - Ord(SPS.FrameOnly));
  if CodedPixels > AVCPictureLimit then
    raise ESWFError.Create('FLV AVC picture size limit');
  FCodedPixels := Max(FCodedPixels, CodedPixels);
  // Reserve space for reference pictures, motion data, decoder scratch space
  // and pictures waiting for presentation. Frame bitmaps use the video pool.
  FMemory := Max(FMemory, Int64(CodedPixels) * (24 + 8 * Max(1, SPS.MaxRefs)) +
    Min(AVCCacheBytes, Int64(CodedPixels) * 12));
end;

procedure TFLVAVCStream.AddConfiguration(const Config: TBytes);
var
  NAL: TBytes;
  HasPPS: Boolean;
begin
  if (FConfigurations.Count > 0) and (Length(Config) = Length(FConfigurations.Last)) and
    CompareMem(Pointer(Config), Pointer(FConfigurations.Last), Length(Config)) then
    Exit;
  FCodedPixels := 0;
  HasPPS := False;
  try
    for NAL in ParseAVCC(Config, FNALLength) do
      case NAL[0] and 31 of
        7:
          ReadSequence(NAL);
        8:
          HasPPS := True;
      end;
  except
    on E: EPlayerError do
      raise ESWFError.Create('FLV AVC configuration: ' + E.Message);
  end;
  if (FCodedPixels = 0) or not HasPPS then
    raise ESWFError.Create('FLV AVC configuration requires SPS and PPS');
  FConfigurations.Add(Config);
  FLastKey := -1;
end;

procedure TFLVAVCStream.AddAccessUnit(const Data: TBytes; DecodeTime, PresentationTime: Int64);
var
  NAL: TBytes;
  Packet: TAccessUnit;
  HasPicture, IDR: Boolean;
begin
  if FConfigurations.Count = 0 then
    raise ESWFError.Create('FLV AVC data precedes its configuration');
  if (FPackets.Count >= 65535) or (Length(Data) = 0) or (DecodeTime < FLastDecodeTime) then
    raise ESWFError.Create('Invalid FLV AVC access unit, timestamp or frame count');
  FLastDecodeTime := DecodeTime;
  HasPicture := False;
  IDR := False;
  try
    for NAL in SplitAVCPacket(Data, FNALLength) do
      case NAL[0] and 31 of
        1:
          HasPicture := True;
        5:
          begin
            HasPicture := True;
            IDR := True;
          end;
        7:
          ReadSequence(NAL);
      end;
  except
    on E: EPlayerError do
      raise ESWFError.Create('FLV AVC packet: ' + E.Message);
  end;
  if not HasPicture and (FLastKey < 0) then
    Exit;
  if IDR then
    FLastKey := FPackets.Count;
  if FLastKey < 0 then
    raise ESWFError.Create('FLV AVC configuration has no initial IDR picture');
  Packet := Default(TAccessUnit);
  Packet.Data := Data;
  Packet.Time := PresentationTime;
  Packet.ConfigIndex := FConfigurations.Count - 1;
  Packet.KeyIndex := FLastKey;
  Packet.CodedPixels := FCodedPixels;
  Packet.Presentation := -1;
  if HasPicture then
    Packet.Presentation := 0;
  FPackets.Add(Packet);
end;

procedure TFLVAVCStream.Finish(out Times: TArray<Int64>);
var
  I, Count: Integer;
  Packet: TAccessUnit;
begin
  SetLength(FPresentation, FPackets.Count);
  Count := 0;
  for I := 0 to FPackets.Count - 1 do
    if FPackets[I].Presentation >= 0 then
    begin
      FPresentation[Count].Time := FPackets[I].Time;
      FPresentation[Count].DecodeIndex := I;
      Inc(Count);
    end;
  SetLength(FPresentation, Count);
  if Count = 0 then
    raise ESWFError.Create('FLV contains no AVC pictures');
  TArray.Sort<TPresentation>(FPresentation, TComparer<TPresentation>.Construct(
    function(const Left, Right: TPresentation): Integer
    begin
      if Left.Time < Right.Time then
        Exit(-1);
      if Left.Time > Right.Time then
        Exit(1);
      Result := Left.DecodeIndex - Right.DecodeIndex;
    end));
  SetLength(Times, Count);
  for I := 0 to High(FPresentation) do
  begin
    Times[I] := FPresentation[I].Time;
    Packet := FPackets[FPresentation[I].DecodeIndex];
    Packet.Presentation := I;
    FPackets[FPresentation[I].DecodeIndex] := Packet;
  end;
end;

function TFLVAVCStream.KeyFrameBefore(Number: Integer): Integer;
begin
  Result := -1;
  if (Number >= 0) and (Number < Length(FPresentation)) then
    Result := FPackets[FPackets[FPresentation[Number].DecodeIndex].KeyIndex].Presentation;
end;

procedure PublishFrame(const Frame: TVideoFrame; var Bitmap: IImagePixelBuffer; const Pool: IImagePixelPool);
var
  X, Y, Luma, Chroma, U, V, R, G, B, YScale, YOffset, RV, GU, GV, BU: Integer;
  Output: IImagePixelBuffer;
begin
  YScale := 76309;
  YOffset := 16;
  if Frame.Matrix = TColorMatrix.BT709 then
  begin
    RV := 117489;
    GU := 13975;
    GV := 34925;
    BU := 138438;
  end
  else
  begin
    RV := 104597;
    GU := 25675;
    GV := 53279;
    BU := 132201;
  end;
  if Frame.FullRange then
  begin
    YScale := 65536;
    YOffset := 0;
    RV := RV * 224 div 255;
    GU := GU * 224 div 255;
    GV := GV * 224 div 255;
    BU := BU * 224 div 255;
  end;
  Output := Bitmap;
  if (Output = nil) or (Output.Width <> Frame.Width) or (Output.Height <> Frame.Height) then
    Output := Pool.Allocate(Frame.Width, Frame.Height, False, 0);
  if Output = nil then
    raise ESWFError.Create('Flash video bitmap pool limit');
  for Y := 0 to Frame.Height - 1 do
    for X := 0 to Frame.Width - 1 do
    begin
      Luma := (Integer(Frame.Planes[0][Y * Frame.Strides[0] + X]) - YOffset) * YScale + 32768;
      Chroma := (Y div 2) * Frame.Strides[1] + X div 2;
      U := Integer(Frame.Planes[1][Chroma]) - 128;
      Chroma := (Y div 2) * Frame.Strides[2] + X div 2;
      V := Integer(Frame.Planes[2][Chroma]) - 128;
      R := EnsureRange((Luma + RV * V) div 65536, 0, 255);
      G := EnsureRange((Luma - GU * U - GV * V) div 65536, 0, 255);
      B := EnsureRange((Luma + BU * U) div 65536, 0, 255);
      Output.SetPixelPremultiplied(X, Y, $FF000000 or (Cardinal(R) shl 16) or
        (Cardinal(G) shl 8) or Cardinal(B));
    end;
  Bitmap := Output;
end;

procedure TFLVAVCStream.Seek(Number: Integer; var State: TSWFVideoState; const Pool: IImagePixelPool; var Work: Int64; WorkLimit: Integer);
var
  Index, Key, J, Kept: Integer;
  Count, Cost: Int64;
  Packet: TAccessUnit;
  Track: TTrackInfo;
  Input: TMediaPacket;
  Frame, Target: TVideoFrame;
begin
  if (Number < 0) or (Number >= Length(FPresentation)) or
    ((State.Bitmap <> nil) and (State.Position = Number)) then
    Exit;
  Index := FPresentation[Number].DecodeIndex;
  Key := FPackets[Index].KeyIndex;
  if (State.AVC.Decoder = nil) or (State.AVC.NextPacket <= Key) or
    (State.AVC.StartPacket > Key) or (Number < State.AVC.Request) then
  begin
    State.AVC := Default(TSWFAVCVideoState);
    State.AVC.StartPacket := Key;
    State.AVC.NextPacket := Key;
  end;
  State.AVC.Request := Number;
  Target := Default(TVideoFrame);
  Count := 0;
  Kept := 0;
  for J := 0 to High(State.AVC.Frames) do
  begin
    Frame := State.AVC.Frames[J];
    if Frame.PTS = Number then
      Target := Frame
    else if Frame.PTS > Number then
    begin
      State.AVC.Frames[Kept] := Frame;
      Inc(Kept);
      Inc(Count, Length(Frame.Planes[0]) + Length(Frame.Planes[1]) + Length(Frame.Planes[2]));
    end;
  end;
  SetLength(State.AVC.Frames, Kept);
  try
    while State.AVC.NextPacket <= Index do
    begin
      Packet := FPackets[State.AVC.NextPacket];
      Cost := 2 * Int64(Packet.CodedPixels) + Length(Packet.Data);
      if Cost > WorkLimit then
        raise ESWFError.Create('FLV AVC picture exceeds the decoding work limit');
      if Work + Cost > WorkLimit then
        Exit;
      Inc(Work, Cost);
      if State.AVC.Decoder = nil then
      begin
        Track := Default(TTrackInfo);
        Track.Codec := 'avc1';
        Track.CodecConfig := FConfigurations[Packet.ConfigIndex];
        State.AVC.Decoder := TH264Decoder.Create(False, True);
        State.AVC.Decoder.Configure(Track);
      end;
      Input := Default(TMediaPacket);
      Input.Data := Packet.Data;
      // In decode-order mode the decoder preserves this unique presentation
      // index. The FLV clock keeps the corresponding millisecond timestamps.
      Input.PTS := Packet.Presentation;
      Input.KeyFrame := State.AVC.NextPacket = Packet.KeyIndex;
      State.AVC.Decoder.Send(Input);
      Inc(State.AVC.NextPacket);
      while State.AVC.Decoder.Receive(Frame) do
        if Frame.PTS = Number then
          Target := Frame
        else if Frame.PTS > Number then
        begin
          Inc(Count, Length(Frame.Planes[0]) + Length(Frame.Planes[1]) + Length(Frame.Planes[2]));
          if (Count > AVCCacheBytes) or (Length(State.AVC.Frames) >= 32) then
            raise ESWFError.Create('FLV AVC presentation queue limit');
          Kept := Length(State.AVC.Frames);
          SetLength(State.AVC.Frames, Kept + 1);
          State.AVC.Frames[Kept] := Frame;
        end;
    end;
  except
    on E: EPlayerError do
    begin
      State.AVC := Default(TSWFAVCVideoState);
      raise ESWFError.Create('FLV AVC decode: ' + E.Message);
    end;
  end;
  if Target.Width = 0 then
    raise ESWFError.Create('FLV AVC access unit has no decoded picture');
  PublishFrame(Target, State.Bitmap, Pool);
  State.Position := Number;
end;

end.

