unit PSP.Jpeg;

// sceJpeg: the Media Engine's Motion JPEG decoder and its colour conversion.
// The decoder is a baseline (ITU T.81 sequential DCT, Huffman) one that
// hands out the planes in the ME's layout: luma, then each chroma plane at its
// sampled size.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel,
  PSP.Scheduler, PSP.Service;

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
  TPSPJpegImage = record
    Width, Height: Integer;
    // Sampling of the first component relative to the others (2,2 for 4:2:0).
    H, V: Integer;
    Components: Integer;
    Planes: array[0..2] of TBytes;
    PlaneWidth, PlaneHeight: array[0..2] of Integer;
  end;

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
  ZigZag: array[0..63] of Byte = (
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63);

type
  THuffTable = record
    Valid: Boolean;
    // Canonical decoding: per code length, the first code, first index and count.
    MinCode, MaxCode: array[1..16] of Integer;
    ValPtr: array[1..16] of Integer;
    Values: array[0..255] of Byte;
  end;

  TComponent = record
    Id, H, V, Tq: Integer;
    Td, Ta: Integer;
    Pred: Integer;
    BlocksW, BlocksH: Integer;
    Data: TBytes;
  end;

  TBits = record
    Data: TBytes;
    Pos, Stop: Integer;
    Buf: Cardinal;
    Count: Integer;
    Marker: Boolean;
    procedure Init(const D: TBytes; Start: Integer);
    function Bit: Integer;
    function Bits(N: Integer): Integer;
    procedure Reset;
  end;

procedure TBits.Init(const D: TBytes; Start: Integer);
begin
  Data := D;
  Pos := Start;
  Stop := Length(D);
  Buf := 0;
  Count := 0;
  Marker := False;
end;

procedure TBits.Reset;
begin
  Buf := 0;
  Count := 0;
  Marker := False;
end;

function TBits.Bit: Integer;
begin
  if Count = 0 then
  begin
    var B: Cardinal := 0;
    if not Marker and (Pos < Stop) then
    begin
      B := Data[Pos];
      if B = $FF then
      begin
        if (Pos + 1 < Stop) and (Data[Pos + 1] = 0) then
          Inc(Pos, 2)
        else
        begin
          Marker := True;
          B := 0;
        end;
      end
      else
        Inc(Pos);
    end;
    Buf := B;
    Count := 8;
  end;
  Dec(Count);
  Result := (Buf shr Count) and 1;
end;

function TBits.Bits(N: Integer): Integer;
begin
  Result := 0;
  for var I := 1 to N do
    Result := (Result shl 1) or Bit;
end;

function DecodeHuff(var B: TBits; const T: THuffTable): Integer;
begin
  var Code := B.Bit;
  for var L := 1 to 16 do
  begin
    if (T.MaxCode[L] >= 0) and (Code <= T.MaxCode[L]) and (Code >= T.MinCode[L]) then
      Exit(T.Values[T.ValPtr[L] + Code - T.MinCode[L]]);
    Code := (Code shl 1) or B.Bit;
  end;
  Result := 0;
end;

function Extend(V, T: Integer): Integer; inline;
begin
  if (T > 0) and (V < (1 shl (T - 1))) then
    Result := V - (1 shl T) + 1
  else
    Result := V;
end;

// Integer inverse DCT (scaled, separable, 13-bit constants).
procedure Idct(var Blk: array of Integer; Dest: PByte; Stride: Integer);
const
  C1 = 4017;
  C2 = 3784;
  C3 = 3406;
  C5 = 2276;
  C6 = 1567;
  C7 = 799;
  S = 2896;
var
  W: array[0..63] of Integer;
begin
  for var I := 0 to 7 do
  begin
    var X0 := Blk[I * 8 + 0];
    var X1 := Blk[I * 8 + 1];
    var X2 := Blk[I * 8 + 2];
    var X3 := Blk[I * 8 + 3];
    var X4 := Blk[I * 8 + 4];
    var X5 := Blk[I * 8 + 5];
    var X6 := Blk[I * 8 + 6];
    var X7 := Blk[I * 8 + 7];
    var A0 := (X0 + X4) * S;
    var A1 := (X0 - X4) * S;
    var A2 := X2 * C6 - X6 * C2;
    var A3 := X2 * C2 + X6 * C6;
    var E0 := A0 + A3;
    var E3 := A0 - A3;
    var E1 := A1 + A2;
    var E2 := A1 - A2;
    var O0 := X1 * C1 + X3 * C3 + X5 * C5 + X7 * C7;
    var O1 := X1 * C3 - X3 * C7 - X5 * C1 - X7 * C5;
    var O2 := X1 * C5 - X3 * C1 + X5 * C7 + X7 * C3;
    var O3 := X1 * C7 - X3 * C5 + X5 * C3 - X7 * C1;
    W[I * 8 + 0] := (E0 + O0 + 1024) div 2048;
    W[I * 8 + 7] := (E0 - O0 + 1024) div 2048;
    W[I * 8 + 1] := (E1 + O1 + 1024) div 2048;
    W[I * 8 + 6] := (E1 - O1 + 1024) div 2048;
    W[I * 8 + 2] := (E2 + O2 + 1024) div 2048;
    W[I * 8 + 5] := (E2 - O2 + 1024) div 2048;
    W[I * 8 + 3] := (E3 + O3 + 1024) div 2048;
    W[I * 8 + 4] := (E3 - O3 + 1024) div 2048;
  end;
  for var I := 0 to 7 do
  begin
    var X0 := W[0 * 8 + I];
    var X1 := W[1 * 8 + I];
    var X2 := W[2 * 8 + I];
    var X3 := W[3 * 8 + I];
    var X4 := W[4 * 8 + I];
    var X5 := W[5 * 8 + I];
    var X6 := W[6 * 8 + I];
    var X7 := W[7 * 8 + I];
    var A0 := (X0 + X4) * S;
    var A1 := (X0 - X4) * S;
    var A2 := X2 * C6 - X6 * C2;
    var A3 := X2 * C2 + X6 * C6;
    var E0 := A0 + A3;
    var E3 := A0 - A3;
    var E1 := A1 + A2;
    var E2 := A1 - A2;
    var O0 := X1 * C1 + X3 * C3 + X5 * C5 + X7 * C7;
    var O1 := X1 * C3 - X3 * C7 - X5 * C1 - X7 * C5;
    var O2 := X1 * C5 - X3 * C1 + X5 * C7 + X7 * C3;
    var O3 := X1 * C7 - X3 * C5 + X5 * C3 - X7 * C1;
    var R: array[0..7] of Integer;
    R[0] := E0 + O0;
    R[7] := E0 - O0;
    R[1] := E1 + O1;
    R[6] := E1 - O1;
    R[2] := E2 + O2;
    R[5] := E2 - O2;
    R[3] := E3 + O3;
    R[4] := E3 - O3;
    for var Y := 0 to 7 do
    begin
      // Rows were scaled by 4096/2048, columns by 4096 and 8 for the DCT's normalisation.
      var V := R[Y];
      if V >= 0 then
        V := (V + 16384) shr 15
      else
        V := -((-V + 16383) shr 15);
      Inc(V, 128);
      if V < 0 then
        V := 0
      else if V > 255 then
        V := 255;
      Dest[Y * Stride + I] := V;
    end;
  end;
end;

function DecodeJpeg(const Data: TBytes; HeaderOnly: Boolean; out Image: TPSPJpegImage): Cardinal;
var
  Quant: array[0..3, 0..63] of Integer;
  Dc, Ac: array[0..3] of THuffTable;
  Comps: array[0..3] of TComponent;
  NComp, Restart: Integer;
  HMax, VMax: Integer;
  Frame: Boolean;

  procedure BuildHuff(var T: THuffTable; const Counts: array of Byte; P: Integer);
  begin
    T := Default(THuffTable);
    T.Valid := True;
    var Code := 0;
    var K := 0;
    for var L := 1 to 16 do
    begin
      T.ValPtr[L] := K;
      T.MinCode[L] := Code;
      Inc(Code, Counts[L - 1]);
      Inc(K, Counts[L - 1]);
      if Counts[L - 1] > 0 then
        T.MaxCode[L] := Code - 1
      else
        T.MaxCode[L] := -1;
      Code := Code shl 1;
    end;
    for var I := 0 to Min(K, 256) - 1 do
      if P + I < Length(Data) then
        T.Values[I] := Data[P + I];
  end;

begin
  Image := Default(TPSPJpegImage);
  if (Length(Data) < 2) or (Data[0] <> $FF) or (Data[1] <> $D8) then
    Exit(ERROR_JPEG_NO_SOI);
  FillChar(Quant, SizeOf(Quant), 0);
  FillChar(Dc, SizeOf(Dc), 0);
  FillChar(Ac, SizeOf(Ac), 0);
  NComp := 0;
  Restart := 0;
  Frame := False;
  HMax := 1;
  VMax := 1;
  var P := 2;
  while True do
  begin
    while (P < Length(Data)) and (Data[P] <> $FF) do
      Inc(P);
    while (P < Length(Data)) and (Data[P] = $FF) do
      Inc(P);
    if P >= Length(Data) then
      Exit(ERROR_JPEG_NO_SOI);
    var M := Data[P];
    Inc(P);
    if M = $D9 then
      Exit(ERROR_JPEG_NO_SOI);
    if (M >= $D0) and (M <= $D7) or (M = $01) then
      Continue;
    if P + 2 > Length(Data) then
      Exit(ERROR_JPEG_BAD_MARKER_LENGTH);
    var Len := (Integer(Data[P]) shl 8) or Data[P + 1];
    if (Len < 2) or (P + Len > Length(Data)) then
      Exit(ERROR_JPEG_BAD_MARKER_LENGTH);
    var Q := P + 2;
    var Next := P + Len;
    case M of
      $DB:
        while Q < Next do
        begin
          var Pq := Data[Q] shr 4;
          var Tq := Data[Q] and 3;
          Inc(Q);
          for var I := 0 to 63 do
            if Pq = 0 then
            begin
              Quant[Tq, ZigZag[I]] := Data[Q];
              Inc(Q);
            end
            else
            begin
              Quant[Tq, ZigZag[I]] := (Integer(Data[Q]) shl 8) or Data[Q + 1];
              Inc(Q, 2);
            end;
        end;
      $C4:
        while Q + 17 <= Next do
        begin
          var Tc := Data[Q] shr 4;
          var Th := Data[Q] and 3;
          var Counts: array[0..15] of Byte;
          var Total := 0;
          for var I := 0 to 15 do
          begin
            Counts[I] := Data[Q + 1 + I];
            Inc(Total, Counts[I]);
          end;
          if Tc = 0 then
            BuildHuff(Dc[Th], Counts, Q + 17)
          else
            BuildHuff(Ac[Th], Counts, Q + 17);
          Inc(Q, 17 + Total);
        end;
      $DD:
        Restart := (Integer(Data[Q]) shl 8) or Data[Q + 1];
      $C0, $C1:
        begin
          Image.Height := (Integer(Data[Q + 1]) shl 8) or Data[Q + 2];
          Image.Width := (Integer(Data[Q + 3]) shl 8) or Data[Q + 4];
          NComp := Data[Q + 5];
          if (NComp < 1) or (NComp > 3) then
            Exit(ERROR_JPEG_UNSUPPORT_COLORSPACE);
          for var I := 0 to NComp - 1 do
          begin
            Comps[I] := Default(TComponent);
            Comps[I].Id := Data[Q + 6 + I * 3];
            Comps[I].H := Data[Q + 7 + I * 3] shr 4;
            Comps[I].V := Data[Q + 7 + I * 3] and 15;
            Comps[I].Tq := Data[Q + 8 + I * 3] and 3;
            HMax := Max(HMax, Comps[I].H);
            VMax := Max(VMax, Comps[I].V);
          end;
          Image.Components := NComp;
          Image.H := Comps[0].H;
          Image.V := Comps[0].V;
          Frame := True;
          // The ME decodes 4:2:0 only.
          if (NComp <> 3) or (Comps[0].H <> 2) or (Comps[0].V <> 2) or (Comps[1].H <> 1) or (Comps[1].V <> 1) or
            (Comps[2].H <> 1) or (Comps[2].V <> 1) then
            Exit(ERROR_JPEG_UNSUPPORT_SAMPLING);
          if HeaderOnly then
            Exit(0);
        end;
      $C2, $C3, $C5..$C7, $C9..$CB, $CD..$CF:
        Exit(ERROR_JPEG_UNSUPPORT_COLORSPACE);
      $DA:
        begin
          if not Frame then
            Exit(ERROR_JPEG_NO_SOI);
          Break;
        end;
    end;
    P := Next;
  end;
  // Scan header.
  var Q := P + 2;
  var Ns := Data[Q];
  Inc(Q);
  for var I := 0 to Ns - 1 do
  begin
    var Cid := Data[Q];
    for var C := 0 to NComp - 1 do
      if Comps[C].Id = Cid then
      begin
        Comps[C].Td := Data[Q + 1] shr 4;
        Comps[C].Ta := Data[Q + 1] and 3;
      end;
    Inc(Q, 2);
  end;
  Inc(Q, 3);
  var McuW := 8 * HMax;
  var McuH := 8 * VMax;
  var McusX := (Image.Width + McuW - 1) div McuW;
  var McusY := (Image.Height + McuH - 1) div McuH;
  for var C := 0 to NComp - 1 do
  begin
    Comps[C].BlocksW := McusX * Comps[C].H;
    Comps[C].BlocksH := McusY * Comps[C].V;
    SetLength(Comps[C].Data, Comps[C].BlocksW * 8 * Comps[C].BlocksH * 8);
    Comps[C].Pred := 0;
  end;
  var B: TBits;
  B.Init(Data, Q);
  var Blk: array[0..63] of Integer;
  var McuCount := 0;
  for var MY := 0 to McusY - 1 do
    for var MX := 0 to McusX - 1 do
    begin
      if (Restart > 0) and (McuCount > 0) and (McuCount mod Restart = 0) then
      begin
        // Skip to the RSTn marker and start over.
        B.Reset;
        while (B.Pos + 1 < Length(Data)) and not ((Data[B.Pos] = $FF) and (Data[B.Pos + 1] >= $D0) and
          (Data[B.Pos + 1] <= $D7)) do
          Inc(B.Pos);
        Inc(B.Pos, 2);
        for var C := 0 to NComp - 1 do
          Comps[C].Pred := 0;
      end;
      Inc(McuCount);
      for var C := 0 to NComp - 1 do
        for var BY := 0 to Comps[C].V - 1 do
          for var BX := 0 to Comps[C].H - 1 do
          begin
            FillChar(Blk, SizeOf(Blk), 0);
            var T := DecodeHuff(B, Dc[Comps[C].Td]);
            var Diff := 0;
            if T > 0 then
              Diff := Extend(B.Bits(T), T);
            Inc(Comps[C].Pred, Diff);
            Blk[0] := Comps[C].Pred * Quant[Comps[C].Tq, 0];
            var K := 1;
            while K < 64 do
            begin
              var RS := DecodeHuff(B, Ac[Comps[C].Ta]);
              var R := RS shr 4;
              var S := RS and 15;
              if S = 0 then
              begin
                if R = 15 then
                begin
                  Inc(K, 16);
                  Continue;
                end;
                Break;
              end;
              Inc(K, R);
              if K > 63 then
                Break;
              Blk[ZigZag[K]] := Extend(B.Bits(S), S) * Quant[Comps[C].Tq, ZigZag[K]];
              Inc(K);
            end;
            var Stride := Comps[C].BlocksW * 8;
            var X0 := (MX * Comps[C].H + BX) * 8;
            var Y0 := (MY * Comps[C].V + BY) * 8;
            Idct(Blk, @Comps[C].Data[Y0 * Stride + X0], Stride);
          end;
    end;
  // Crop each plane to its sampled size.
  for var C := 0 to NComp - 1 do
  begin
    var W := (Image.Width * Comps[C].H + HMax - 1) div HMax;
    var H := (Image.Height * Comps[C].V + VMax - 1) div VMax;
    Image.PlaneWidth[C] := W;
    Image.PlaneHeight[C] := H;
    SetLength(Image.Planes[C], W * H);
    var Stride := Comps[C].BlocksW * 8;
    for var Y := 0 to H - 1 do
      Move(Comps[C].Data[Y * Stride], Image.Planes[C][Y * W], W);
  end;
  Result := 0;
end;

function PSPDecodeJpeg(const Data: TBytes; HeaderOnly: Boolean; out Image: TPSPJpegImage): Cardinal;
begin
  try
    Result := DecodeJpeg(Data, HeaderOnly, Image);
  except
    // Damaged data the parser ran off the end of.
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

