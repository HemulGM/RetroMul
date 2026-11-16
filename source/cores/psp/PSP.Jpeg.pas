unit PSP.Jpeg;

// sceJpeg: the Media Engine's Motion JPEG decoder and its colour conversion.
// The decoder is a baseline (ITU T.81 sequential DCT, Huffman) one that
// hands out the planes in the ME's layout: luma, then each chroma plane at its
// sampled size.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel,
  PSP.Scheduler, PSP.Service, Media.Image.JPEG;

const
  ERROR_JPEG_BAD_MARKER_LENGTH = Cardinal($80650004);
  ERROR_JPEG_INVALID_POINTER = Cardinal($80650010);
  ERROR_JPEG_UNSUPPORT_COLORSPACE = Cardinal($80650013);
  ERROR_JPEG_UNSUPPORT_SAMPLING = Cardinal($80650016);
  ERROR_JPEG_UNSUPPORT_IMAGE_SIZE = Cardinal($80650020);
  ERROR_JPEG_NO_SOI = Cardinal($80650023);
  ERROR_JPEG_INVALID_STATE = Cardinal($80650039);
  ERROR_JPEG_OUT_OF_MEMORY = Cardinal($80650041);
  ERROR_JPEG_ALREADY_INIT = Cardinal($80650042);
  ERROR_JPEG_INVALID_VALUE = Cardinal($80650051);

type
  TPSPJpegImage = TJPEGPlanes;

// Baseline JPEG. Returns 0 or an sceJpeg error.
function PSPDecodeJpeg(const Data: TBytes; HeaderOnly: Boolean; out Image: TPSPJpegImage): Cardinal;

type
  TPSPJpeg = class(TPSPService)
  private
    FInit, FFinished, FCreated: Boolean;
    // The colour converter ran: the ME is up and InitMJpeg does not wait for it.
    FMEReady: Boolean;
    FWidth, FHeight: Integer;
    procedure Delay(Us: Int64; Value: Cardinal);
    function ReadJpeg(Address, Size: Cardinal; out Data: TBytes): Cardinal;
    procedure WriteRgba(const Img: TPSPJpegImage; Dest: Cardinal; Stride: Integer);
    procedure Convert(Dest, Src: Cardinal; Width, Height, Stride, ChromaH, ChromaV: Integer; MJpeg: Boolean);
    procedure hInitMJpeg;
    procedure hFinishMJpeg;
    procedure hCreateMJpeg;
    procedure hDeleteMJpeg;
    procedure hDecodeMJpeg;
    procedure hDecodeMJpegYCbCr;
    procedure hDecodeMJpegYCbCrSuccessively;
    procedure hGetOutputInfo;
    procedure hCsc;
    procedure hMJpegCsc;
    procedure DecodeYCbCr(Successive: Boolean);
  public
    procedure Reset; override;
    procedure Register; override;
  end;

implementation

uses
  System.Math;

const
  LibJpeg = 'sceJpeg';

function PSPDecodeJpeg(const Data: TBytes; HeaderOnly: Boolean; out Image: TPSPJpegImage): Cardinal;
const
  Errors: array[TJPEGStatus] of Cardinal = (0, ERROR_JPEG_NO_SOI, ERROR_JPEG_BAD_MARKER_LENGTH,
    ERROR_JPEG_UNSUPPORT_COLORSPACE, ERROR_JPEG_UNSUPPORT_SAMPLING, ERROR_JPEG_UNSUPPORT_IMAGE_SIZE, ERROR_JPEG_NO_SOI);
begin
  try
    // PSP Media Engine policy remains 4:2:0; the shared native decoder also
    // serves ordinary grayscale/RGB images for other cores.
    Result := Errors[DecodeJPEGPlanes(Data, HeaderOnly, True, Image)];
  except
    on E: Exception do
    begin
      Image := Default(TPSPJpegImage);
      Result := ERROR_JPEG_NO_SOI;
    end;
  end;
end;

{ TPSPJpeg }

procedure TPSPJpeg.Reset;
begin
  FInit := False;
  FFinished := False;
  FCreated := False;
  FMEReady := False;
  FWidth := 0;
  FHeight := 0;
end;

procedure TPSPJpeg.Register;
begin
  var H := FHLE;
  H.Register(LibJpeg, $AC9E70E6, 'sceJpegInitMJpeg', hInitMJpeg);
  H.Register(LibJpeg, $7D2F3D7F, 'sceJpegFinishMJpeg', hFinishMJpeg);
  H.Register(LibJpeg, $9D47469C, 'sceJpegCreateMJpeg', hCreateMJpeg);
  H.Register(LibJpeg, $48B602B7, 'sceJpegDeleteMJpeg', hDeleteMJpeg);
  H.Register(LibJpeg, $04B93CEF, 'sceJpegDecodeMJpeg', hDecodeMJpeg);
  H.Register(LibJpeg, $64B6F978, 'sceJpegDecodeMJpegSuccessively', hDecodeMJpeg);
  H.Register(LibJpeg, $91EED83C, 'sceJpegDecodeMJpegYCbCr', hDecodeMJpegYCbCr);
  H.Register(LibJpeg, $227662D7, 'sceJpegDecodeMJpegYCbCrSuccessively', hDecodeMJpegYCbCrSuccessively);
  H.Register(LibJpeg, $8F2BB012, 'sceJpegGetOutputInfo', hGetOutputInfo);
  H.Register(LibJpeg, $67F0ED84, 'sceJpegCsc', hCsc);
  H.Register(LibJpeg, $04B5AE02, 'sceJpegMJpegCsc', hMJpegCsc);
end;

procedure TPSPJpeg.Delay(Us: Int64; Value: Cardinal);
begin
  FHLE.Result(Value);
  if not FKernel.CanWait then
    Exit;
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitDelay, nil, 0, 0, False, nil, nil, 'jpeg');
  if T.Wait.HLETag <> 'jpeg' then
    Exit;
  T.Wait.Data[0] := Value;
  FKernel.AddWakeTimer(FKernel.Scheduler.Now + Us * 1000, T, 'jpeg', Value, 0);
end;

procedure TPSPJpeg.hInitMJpeg;
begin
  if FInit then
  begin
    FHLE.Result(ERROR_JPEG_ALREADY_INIT);
    Exit;
  end;
  FInit := True;
  FFinished := False;
  if FMEReady then
    FHLE.Result(0)
  else
    Delay(1000, 0);
end;

procedure TPSPJpeg.hFinishMJpeg;
begin
  if not FInit or FCreated then
  begin
    FHLE.Result(ERROR_JPEG_INVALID_STATE);
    Exit;
  end;
  FInit := False;
  FFinished := True;
  Delay(1000, 0);
end;

procedure TPSPJpeg.hCreateMJpeg;
begin
  var W := FHLE.ArgInt(0);
  var H := FHLE.ArgInt(1);
  if not FInit or FCreated then
  begin
    FHLE.Result(ERROR_JPEG_INVALID_STATE);
    Exit;
  end;
  if W > 1024 then
  begin
    FHLE.Result(ERROR_JPEG_UNSUPPORT_IMAGE_SIZE);
    Exit;
  end;
  FCreated := True;
  FWidth := W;
  FHeight := H;
  FHLE.Result(0);
end;

procedure TPSPJpeg.hDeleteMJpeg;
begin
  if not FInit or not FCreated then
  begin
    FHLE.Result(ERROR_JPEG_INVALID_STATE);
    Exit;
  end;
  FCreated := False;
  FHLE.Result(0);
end;

function TPSPJpeg.ReadJpeg(Address, Size: Cardinal; out Data: TBytes): Cardinal;
begin
  Data := nil;
  if Address = 0 then
    Exit(ERROR_JPEG_NO_SOI);
  if Size = 0 then
    Exit(ERROR_JPEG_BAD_MARKER_LENGTH);
  SetLength(Data, Size);
  FMemory.ReadBytes(Address, Data[0], Size);
  Result := 0;
end;

function SarFloor(V: Integer): Integer; inline;
begin
  if V >= 0 then
    Result := V shr 8
  else
    Result := -((-V + 255) shr 8);
end;

function DecodeTimeUs(const Img: TPSPJpegImage): Int64;
begin
  Result := 200 + Int64(Img.Width) * Img.Height div 100;
end;

procedure TPSPJpeg.WriteRgba(const Img: TPSPJpegImage; Dest: Cardinal; Stride: Integer);
begin
  var CW := Img.PlaneWidth[1];
  for var Y := 0 to Img.Height - 1 do
    for var X := 0 to Img.Width - 1 do
    begin
      var Yv := Img.Planes[0][Y * Img.PlaneWidth[0] + X];
      var C := (Y div 2) * CW + X div 2;
      var U := Integer(Img.Planes[1][C]) - 128;
      var V := Integer(Img.Planes[2][C]) - 128;
      var R := EnsureRange(Yv + SarFloor(359 * V + 128), 0, 255);
      var G := EnsureRange(Yv - SarFloor(88 * U + 183 * V + 128), 0, 255);
      var B := EnsureRange(Yv + SarFloor(454 * U + 128), 0, 255);
      FMemory.Write32(Dest + Cardinal(Y * Stride + X) * 4, Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16));
    end;
end;

procedure TPSPJpeg.hDecodeMJpeg;
begin
  var Jpeg := FHLE.Arg(0);
  var Size := FHLE.Arg(1);
  var Out_ := FHLE.Arg(2);
  if Size > $00FFFFFF then
  begin
    FHLE.Result($80000023);
    Exit;
  end;
  if FFinished then
  begin
    Delay(200, $80000001);
    Exit;
  end;
  var Data: TBytes;
  var Err := ReadJpeg(Jpeg, Size, Data);
  var Img: TPSPJpegImage;
  if Err = 0 then
    Err := PSPDecodeJpeg(Data, False, Img);
  if Err <> 0 then
  begin
    Delay(200, Err);
    Exit;
  end;
  if Out_ = 0 then
  begin
    Delay(200, SCE_KERNEL_ERROR_INVALID_POINTER);
    Exit;
  end;
  if (Img.Width > FWidth) or (Img.Height > FHeight) then
  begin
    Delay(200, ERROR_JPEG_UNSUPPORT_IMAGE_SIZE);
    Exit;
  end;
  WriteRgba(Img, Out_, FWidth);
  Delay(DecodeTimeUs(Img), (Cardinal(Img.Width) shl 16) or Cardinal(Img.Height));
end;

procedure TPSPJpeg.DecodeYCbCr(Successive: Boolean);
begin
  var Jpeg := FHLE.Arg(0);
  var Size := FHLE.Arg(1);
  var Out_ := FHLE.Arg(2);
  var OutSize := FHLE.Arg(3);
  if (Size > $00FFFFFF) or (Integer(OutSize) < 0) then
  begin
    FHLE.Result($80000023);
    Exit;
  end;
  if (Jpeg = 0) and not Successive then
  begin
    FHLE.Result(ERROR_JPEG_INVALID_VALUE);
    Exit;
  end;
  var Data: TBytes;
  var Err := ReadJpeg(Jpeg, Size, Data);
  var Img: TPSPJpegImage;
  if Err = 0 then
    Err := PSPDecodeJpeg(Data, False, Img);
  if Err <> 0 then
  begin
    Delay(200, Err);
    Exit;
  end;
  var Need := Cardinal(Img.Width * Img.Height + 2 * Img.PlaneWidth[1] * Img.PlaneHeight[1]);
  if OutSize < Need then
  begin
    Delay(200, ERROR_JPEG_OUT_OF_MEMORY);
    Exit;
  end;
  if Out_ = 0 then
  begin
    if Successive then
      Delay(200, ERROR_JPEG_INVALID_POINTER)
    else
    begin
      FHLE.Unimplemented('YCbCr decoding into a NULL buffer');
      Delay(200, (Cardinal(Img.Width) shl 16) or Cardinal(Img.Height));
    end;
    Exit;
  end;
  var A := Out_;
  for var C := 0 to 2 do
  begin
    var N := Length(Img.Planes[C]);
    if N > 0 then
      FMemory.WriteBytes(A, Img.Planes[C][0], N);
    Inc(A, N);
  end;
  Delay(DecodeTimeUs(Img), (Cardinal(Img.Width) shl 16) or Cardinal(Img.Height));
end;

procedure TPSPJpeg.hDecodeMJpegYCbCr;
begin
  DecodeYCbCr(False);
end;

procedure TPSPJpeg.hDecodeMJpegYCbCrSuccessively;
begin
  DecodeYCbCr(True);
end;

procedure TPSPJpeg.hGetOutputInfo;
begin
  var Jpeg := FHLE.Arg(0);
  var Size := FHLE.Arg(1);
  var InfoPtr := FHLE.Arg(2);
  if Size > $00FFFFFF then
  begin
    FHLE.Result($80000023);
    Exit;
  end;
  var Data: TBytes;
  var Err := ReadJpeg(Jpeg, Size, Data);
  var Img: TPSPJpegImage;
  if Err = 0 then
    Err := PSPDecodeJpeg(Data, True, Img);
  if Err <> 0 then
  begin
    Delay(100, Err);
    Exit;
  end;
  if InfoPtr <> 0 then
    FMemory.Write32(InfoPtr, (Cardinal(Img.Components - 1) shl 16) or (Cardinal(Img.H) shl 8) or Cardinal(Img.V));
  var W2 := (Img.Width + 1) div 2;
  var H2 := (Img.Height + 1) div 2;
  Delay(100, Cardinal(Img.Width * Img.Height + 2 * W2 * H2));
end;

procedure TPSPJpeg.Convert(Dest, Src: Cardinal; Width, Height, Stride, ChromaH, ChromaV: Integer; MJpeg: Boolean);
begin
  var CW := (Width + ChromaH - 1) div ChromaH;
  var CH := (Height + ChromaV - 1) div ChromaV;
  var CbBase := Src + Cardinal(Width * Height);
  var CrBase := CbBase + Cardinal(CW * CH);
  var Rows := Height;
  if Rows = 0 then
    Rows := 1;
  for var Y := 0 to Rows - 1 do
  begin
    // Addresses wrap at 32 bits: a huge stride lands rows anywhere.
    var Line := Cardinal(UInt64(Dest) + UInt64(Y) * UInt64(Cardinal(Stride)) * 4);
    for var X := 0 to Width - 1 do
    begin
      var Yv := Integer(FMemory.Read8(Src + Cardinal(Y * Width + X)));
      var C := Cardinal((Y div ChromaV) * CW + X div ChromaH);
      var U := Integer(FMemory.Read8(CbBase + C)) - 128;
      var V := Integer(FMemory.Read8(CrBase + C)) - 128;
      var R, G, B: Integer;
      if MJpeg then
      begin
        if U < -127 then
          U := -127;
        if V < -127 then
          V := -127;
        if V > 126 then
          V := 126;
      end;
      R := EnsureRange(Yv + SarFloor(359 * V + 128), 0, 255);
      G := EnsureRange(Yv - SarFloor(88 * U + 183 * V + 128), 0, 255);
      B := EnsureRange(Yv + SarFloor(454 * U + 128), 0, 255);
      FMemory.Write32(Cardinal(UInt64(Line) + UInt64(X) * 4),
        Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16));
    end;
  end;
end;

procedure TPSPJpeg.hCsc;
begin
  var Dest := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var WH := FHLE.Arg(2);
  var Stride := FHLE.ArgInt(3);
  var Info := FHLE.Arg(4);
  if (Dest = 0) or (Src = 0) then
  begin
    FHLE.Result(ERROR_JPEG_INVALID_VALUE);
    Exit;
  end;
  var Hs := (Info shr 8) and $FF;
  var Vs := Info and $FF;
  if ((Info shr 16) and $F <> 2) or not (((Hs = 2) and (Vs = 2)) or ((Hs = 2) and (Vs = 1)) or
    ((Hs = 1) and (Vs = 1))) then
  begin
    FHLE.Result(ERROR_JPEG_UNSUPPORT_COLORSPACE);
    Exit;
  end;
  var W := Integer(WH shr 16);
  var H := Integer(WH and $FFFF);
  Convert(Dest, Src, W, H, Stride, Hs, Vs, False);
  FMEReady := True;
  var Result_: Cardinal := 0;
  if H = 0 then
    Result_ := $FFFFFFFF;
  Delay(100 + Int64(W) * Max(H, 1) div 200, Result_);
end;

procedure TPSPJpeg.hMJpegCsc;
begin
  var Dest := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var WH := FHLE.Arg(2);
  var Stride := FHLE.ArgInt(3);
  if not FInit then
  begin
    FHLE.Result($80000001);
    Exit;
  end;
  if Dest = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_POINTER);
    Exit;
  end;
  var W := Integer(WH shr 16);
  var H := Integer(WH and $FFFF);
  if (W > 720) or (H > 480) or (Stride > 1024) then
  begin
    FHLE.Result(ERROR_JPEG_UNSUPPORT_IMAGE_SIZE);
    Exit;
  end;
  Convert(Dest, Src, W, H, Stride, 2, 2, True);
  Delay(100 + Int64(W) * Max(H, 1) div 200, 0);
end;

initialization
  RegisterPSPService(TPSPJpeg);

end.

