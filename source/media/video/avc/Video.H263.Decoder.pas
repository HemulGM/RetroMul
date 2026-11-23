unit Video.H263.Decoder;

interface

uses
  Video.AVC.Types;

function CreateH263Decoder: IVideoDecoder;

implementation

uses
  Video.H263.Picture;

type
  TH263Decoder = class(TInterfacedObject, IVideoDecoder)
  private
    FTrack: TTrackInfo;
    FFormat: TH263PictureFormat;
    FReference: TH263Picture;
    FOutput: TVideoFrame;
  public
    procedure Configure(const Track: TTrackInfo);
    procedure Send(const Packet: TMediaPacket);
    function Receive(out Frame: TVideoFrame): Boolean;
    procedure Flush;
    procedure Reset;
    function Kind: TDecoderKind;
  end;

function CreateH263Decoder: IVideoDecoder;
begin
  Result := TH263Decoder.Create;
end;

procedure TH263Decoder.Configure(const Track: TTrackInfo);
begin
  if (Track.Kind <> TTrackKind.Video) or (Track.Codec <> 's263') then
    raise EPlayerUnsupported.Create('Expected a 3GP H.263 track');
  if (Length(Track.CodecConfig) < 7) or (Track.CodecConfig[6] > 8) then
    raise EPlayerUnsupported.Create('Unknown 3GP H.263 profile');
  FTrack := Track;
  Reset;
end;

procedure TH263Decoder.Send(const Packet: TMediaPacket);
var
  Header: TH263PictureHeader;
  Format: TH263PictureFormat;
  Work: Int64;
begin
  if FOutput.Width <> 0 then
    raise EPlayerError.Create('Receive the H.263 picture before sending the next packet');
  ReadH263Header(Packet.Data, FFormat, Header, Format);
  if (Header.Width <> FTrack.Width) or (Header.Height <> FTrack.Height) then
    raise EPlayerUnsupported.Create('H.263 picture size differs from the 3GP track');
  Work := 0;
  FReference := DecodeH263Picture(Packet.Data, Header, FReference, Work, 64 * 1024 * 1024);
  FFormat := Format;
  FOutput.Width := Header.Width;
  FOutput.Height := Header.Height;
  FOutput.SampleAspectNumerator := Header.AspectNumerator;
  FOutput.SampleAspectDenominator := Header.AspectDenominator;
  FOutput.PTS := Packet.PTS;
  FOutput.Duration := Packet.Duration;
  FOutput.Format := TPixelFormat.YUV420P;
  FOutput.Matrix := TColorMatrix.BT601;
  FOutput.Planes[0] := FReference.Y;
  FOutput.Planes[1] := FReference.Cb;
  FOutput.Planes[2] := FReference.Cr;
  FOutput.Strides[0] := FReference.Width;
  FOutput.Strides[1] := FReference.Width div 2;
  FOutput.Strides[2] := FOutput.Strides[1];
end;

function TH263Decoder.Receive(out Frame: TVideoFrame): Boolean;
begin
  Frame := FOutput;
  Result := Frame.Width <> 0;
  if Result then
    FOutput := Default(TVideoFrame);
end;

procedure TH263Decoder.Flush;
begin
  // The supported I and P pictures are emitted immediately.
end;

procedure TH263Decoder.Reset;
begin
  FReference := Default(TH263Picture);
  FFormat := Default(TH263PictureFormat);
  FOutput := Default(TVideoFrame);
end;

function TH263Decoder.Kind: TDecoderKind;
begin
  Result := TDecoderKind.Software;
end;

end.

