unit Media.Image.JPEG;

interface

uses
  System.SysUtils, Media.Image.Types;

type
  TJPEGStatus = (jpegOK, jpegNoSOI, jpegBadMarkerLength, jpegUnsupportedColorSpace,
    jpegUnsupportedSampling, jpegUnsupportedImageSize, jpegInvalidData);

  TJPEGColorSpace = (jpegGray, jpegYCbCr, jpegRGB);

  TJPEGPlanes = record
    Width, Height, H, V, Components: Integer;
    Planes: array[0..2] of TBytes;
    PlaneWidth, PlaneHeight, SampleH, SampleV: array[0..2] of Integer;
    MaxH, MaxV: Integer;
    ColorSpace: TJPEGColorSpace;
  end;

function DecodeJPEGPlanes(const Data: TBytes; HeaderOnly, Restrict420: Boolean; out Image: TJPEGPlanes; MaxPixels: Integer = 16 * 1024 * 1024): TJPEGStatus;

function DecodeJPEG(const Data: TBytes; MaxPixels: Integer = 16 * 1024 * 1024): TRasterImage;

implementation

uses
  System.Math;

{$Q-}{$R-}

type
  EJPEGDecode = class(Exception)
    Status: TJPEGStatus;
    constructor Create(AStatus: TJPEGStatus);
  end;

  THuffTable = record
    Valid: Boolean;
    MinCode, MaxCode, ValPtr: array[1..16] of Integer;
    Values: array[0..255] of Byte;
  end;

  TComponent = record
    Id, H, V, Tq, Td, Ta, Pred, BlocksW, BlocksH: Integer;
    Decoded: Boolean;
    Data: TBytes;
  end;

  TBits = record
    Data: TBytes;
    Pos, Count, Buffer: Integer;
    function Bit: Integer;
    function Bits(N: Integer): Integer;
    procedure Align;
  end;

const
  ZigZag: array[0..63] of Byte = (
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63);

constructor EJPEGDecode.Create(AStatus: TJPEGStatus);
begin
  inherited Create('Invalid or unsupported JPEG');
  Status := AStatus;
end;

procedure Bad(Status: TJPEGStatus = jpegInvalidData);
begin
  raise EJPEGDecode.Create(Status);
end;

function TBits.Bit: Integer;
begin
  if Count = 0 then
  begin
    if Pos >= Length(Data) then
      Bad;
    Buffer := Data[Pos];
    Inc(Pos);
    if Buffer = $FF then
    begin
      if (Pos >= Length(Data)) or (Data[Pos] <> 0) then
        Bad;
      Inc(Pos);
    end;
    Count := 8;
  end;
  Dec(Count);
  Result := (Buffer shr Count) and 1;
end;

function TBits.Bits(N: Integer): Integer;
begin
  Result := 0;
  for var K := 1 to N do
    Result := (Result shl 1) or Bit;
end;

procedure TBits.Align;
begin
  if (Buffer and ((1 shl Count) - 1)) <> (1 shl Count) - 1 then
    Bad;
  Count := 0;
end;

function Huff(var B: TBits; const T: THuffTable): Integer;
begin
  if not T.Valid then
    Bad;
  var Code := 0;
  for var L := 1 to 16 do
  begin
    Code := (Code shl 1) or B.Bit;
    if (T.MaxCode[L] >= 0) and (Code >= T.MinCode[L]) and (Code <= T.MaxCode[L]) then
      Exit(T.Values[T.ValPtr[L] + Code - T.MinCode[L]]);
  end;
  Bad;
  Result := 0;
end;

function Extend(Value, Size: Integer): Integer;
begin
  Result := Value;
  if (Size > 0) and (Value < (1 shl (Size - 1))) then
    Result := Value - (1 shl Size) + 1;
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
  W: array[0..63] of Int64;
begin
  for var I := 0 to 7 do
  begin
    var X0 := Int64(Blk[I * 8 + 0]);
    var X1 := Int64(Blk[I * 8 + 1]);
    var X2 := Int64(Blk[I * 8 + 2]);
    var X3 := Int64(Blk[I * 8 + 3]);
    var X4 := Int64(Blk[I * 8 + 4]);
    var X5 := Int64(Blk[I * 8 + 5]);
    var X6 := Int64(Blk[I * 8 + 6]);
    var X7 := Int64(Blk[I * 8 + 7]);
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
    var R: array[0..7] of Int64;
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

function ReadJPEG(const Data: TBytes; HeaderOnly, Restrict420: Boolean; out Image: TJPEGPlanes; MaxPixels: Integer): TJPEGStatus;
var
  Quant: array[0..3, 0..63] of Integer;
  QuantValid: array[0..3] of Boolean;
  DC, AC: array[0..3] of THuffTable;
  Comps: array[0..2] of TComponent;
  At, EndSegment, NComp, Restart, HMax, VMax, Adobe: Integer;
  Frame: Boolean;

  procedure Need(Count: Integer);
  begin
    if (Count < 0) or (At > EndSegment - Count) then
      Bad(jpegBadMarkerLength);
  end;

  function U8: Integer;
  begin
    Need(1);
    Result := Data[At];
    Inc(At);
  end;

  function U16: Integer;
  begin
    Result := U8 shl 8;
    Result := Result or U8;
  end;

  function Marker: Integer;
  begin
    EndSegment := Length(Data);
    if U8 <> $FF then
      Bad;
    repeat
      Result := U8
    until Result <> $FF;
    if Result = 0 then
      Bad;
  end;

  procedure QuantTable;
  begin
    while At < EndSegment do
    begin
      var Spec := U8;
      var Precision := Spec shr 4;
      var Table := Spec and 15;
      if (Precision > 1) or (Table > 3) then
        Bad;
      Need(64 * (Precision + 1));
      for var K := 0 to 63 do
      begin
        var V := U8;
        if Precision = 1 then
          V := (V shl 8) or U8;
        if V = 0 then
          Bad;
        Quant[Table, ZigZag[K]] := V;
      end;
      QuantValid[Table] := True;
    end;
  end;

  procedure HuffTable;
  begin
    while At < EndSegment do
    begin
      var Spec := U8;
      var Kind := Spec shr 4;
      var Table := Spec and 15;
      if (Kind > 1) or (Table > 3) then
        Bad;
      var T: THuffTable;
      T := Default(THuffTable);
      var Code := 0;
      var Count := 0;
      for var L := 1 to 16 do
      begin
        var N := U8;
        T.MinCode[L] := Code;
        T.MaxCode[L] := -1;
        T.ValPtr[L] := Count;
        if N > 0 then
          T.MaxCode[L] := Code + N - 1;
        Inc(Code, N);
        Inc(Count, N);
        if (Code >= (1 shl L)) or (Count > 256) then
          Bad;
        Code := Code shl 1;
      end;
      if Count = 0 then
        Bad;
      Need(Count);
      for var K := 0 to Count - 1 do
        T.Values[K] := U8;
      T.Valid := True;
      if Kind = 0 then
        DC[Table] := T
      else
        AC[Table] := T;
    end;
  end;

  procedure FrameHeader;
  begin
    if Frame then
      Bad;
    if U8 <> 8 then
      Bad(jpegUnsupportedColorSpace);
    Image.Height := U16;
    Image.Width := U16;
    NComp := U8;
    if (NComp <> 1) and (NComp <> 3) then
      Bad(jpegUnsupportedColorSpace);
    if (Image.Width = 0) or (Image.Height = 0) then
      Bad;
    if (MaxPixels < 1) or (Int64(Image.Width) * Image.Height > MaxPixels) then
      Bad(jpegUnsupportedImageSize);
    Need(NComp * 3);
    HMax := 1;
    VMax := 1;
    var Blocks := 0;
    for var C := 0 to NComp - 1 do
    begin
      var Id := U8;
      var Spec := U8;
      var Q := U8;
      for var Previous := 0 to C - 1 do
        if Comps[Previous].Id = Id then
          Bad;
      Comps[C].Id := Id;
      Comps[C].H := Spec shr 4;
      Comps[C].V := Spec and 15;
      Comps[C].Tq := Q;
      if (Q > 3) or (Comps[C].H < 1) or (Comps[C].H > 4) or (Comps[C].V < 1) or (Comps[C].V > 4) then
        Bad(jpegUnsupportedSampling);
      HMax := Max(HMax, Comps[C].H);
      VMax := Max(VMax, Comps[C].V);
      Inc(Blocks, Comps[C].H * Comps[C].V);
    end;
    if (Blocks > 10) and (NComp > 1) then
      Bad(jpegUnsupportedSampling);
    if Restrict420 and ((NComp <> 3) or (Comps[0].H <> 2) or (Comps[0].V <> 2) or
      (Comps[1].H <> 1) or (Comps[1].V <> 1) or (Comps[2].H <> 1) or (Comps[2].V <> 1)) then
      Bad(jpegUnsupportedSampling);
    Image.H := Comps[0].H;
    Image.V := Comps[0].V;
    Image.Components := NComp;
    if NComp = 1 then
    begin
      HMax := 1;
      VMax := 1;
      Comps[0].H := 1;
      Comps[0].V := 1;
    end;
    Image.MaxH := HMax;
    Image.MaxV := VMax;
    Frame := True;
    if HeaderOnly then
      Exit;
    var Total: Int64 := 0;
    for var C := 0 to NComp - 1 do
    begin
      if (HMax mod Comps[C].H <> 0) or (VMax mod Comps[C].V <> 0) then
        Bad(jpegUnsupportedSampling);
      Comps[C].BlocksW := ((Image.Width + 8 * HMax - 1) div (8 * HMax)) * Comps[C].H;
      Comps[C].BlocksH := ((Image.Height + 8 * VMax - 1) div (8 * VMax)) * Comps[C].V;
      var Size := Int64(Comps[C].BlocksW) * Comps[C].BlocksH * 64;
      Inc(Total, Size);
      if (Total > Int64(MaxPixels) * 4 + 3072) or (Size > High(Integer)) then
        Bad(jpegUnsupportedImageSize);
      SetLength(Comps[C].Data, Integer(Size));
    end;
  end;

  procedure Scan;
  var
    B: TBits;

    procedure Block(C, X, Y: Integer);
    begin
      var Coefficients: array[0..63] of Integer;
      FillChar(Coefficients, SizeOf(Coefficients), 0);
      var Size := Huff(B, DC[Comps[C].Td]);
      if Size > 11 then
        Bad;
      Inc(Comps[C].Pred, Extend(B.Bits(Size), Size));
      if (Comps[C].Pred < -2048) or (Comps[C].Pred > 2047) then
        Bad;
      Coefficients[0] := Comps[C].Pred * Quant[Comps[C].Tq, 0];
      var K := 1;
      while K < 64 do
      begin
        var RS := Huff(B, AC[Comps[C].Ta]);
        var Run := RS shr 4;
        var S := RS and 15;
        if S = 0 then
        begin
          if Run = 0 then
            Break;
          if Run <> 15 then
            Bad;
          Inc(K, 16);
          if K > 64 then
            Bad;
          Continue;
        end;
        if S > 10 then
          Bad;
        Inc(K, Run);
        if K >= 64 then
          Bad;
        Coefficients[ZigZag[K]] := Extend(B.Bits(S), S) * Quant[Comps[C].Tq, ZigZag[K]];
        Inc(K);
      end;
      var Stride := Comps[C].BlocksW * 8;
      Idct(Coefficients, @Comps[C].Data[Y * 8 * Stride + X * 8], Stride);
    end;

  begin
    if not Frame then
      Bad;
    var NS := U8;
    if (NS < 1) or (NS > NComp) then
      Bad;
    var Selected: array[0..2] of Integer;
    for var S := 0 to NS - 1 do
    begin
      var Id := U8;
      var Spec := U8;
      var C := 0;
      while (C < NComp) and (Comps[C].Id <> Id) do
        Inc(C);
      if (C = NComp) or (Spec shr 4 > 3) or (Spec and 15 > 3) then
        Bad;
      for var Previous := 0 to S - 1 do
        if Selected[Previous] = C then
          Bad;
      if Comps[C].Decoded then
        Bad;
      Selected[S] := C;
      Comps[C].Td := Spec shr 4;
      Comps[C].Ta := Spec and 15;
      Comps[C].Pred := 0;
      if not QuantValid[Comps[C].Tq] or not DC[Comps[C].Td].Valid or not AC[Comps[C].Ta].Valid then
        Bad;
    end;
    var SS := U8;
    var SE := U8;
    var Approx := U8;
    if (SS <> 0) or (SE <> 63) or (Approx <> 0) or (At <> EndSegment) then
      Bad;
    var McusX := (Image.Width + 8 * HMax - 1) div (8 * HMax);
    var McusY := (Image.Height + 8 * VMax - 1) div (8 * VMax);
    if NS = 1 then
    begin
      var C := Selected[0];
      McusX := (Image.Width * Comps[C].H + 8 * HMax - 1) div (8 * HMax);
      McusY := (Image.Height * Comps[C].V + 8 * VMax - 1) div (8 * VMax);
    end;
    B := Default(TBits);
    B.Data := Data;
    B.Pos := At;
    var Number := 0;
    var RST := 0;
    for var MY := 0 to McusY - 1 do
      for var MX := 0 to McusX - 1 do
      begin
        if (Restart > 0) and (Number > 0) and (Number mod Restart = 0) then
        begin
          B.Align;
          At := B.Pos;
          if Marker <> $D0 + RST then
            Bad;
          RST := (RST + 1) and 7;
          B.Pos := At;
          for var S := 0 to NS - 1 do
            Comps[Selected[S]].Pred := 0;
        end;
        for var S := 0 to NS - 1 do
        begin
          var C := Selected[S];
          if NS = 1 then
            Block(C, MX, MY)
          else
            for var Y := 0 to Comps[C].V - 1 do
              for var X := 0 to Comps[C].H - 1 do
                Block(C, MX * Comps[C].H + X, MY * Comps[C].V + Y);
        end;
        Inc(Number);
      end;
    B.Align;
    At := B.Pos;
    for var S := 0 to NS - 1 do
      Comps[Selected[S]].Decoded := True;
  end;

begin
  Image := Default(TJPEGPlanes);
  if (Length(Data) < 2) or (Data[0] <> $FF) or (Data[1] <> $D8) then
    Bad(jpegNoSOI);
  if Length(Data) > 64 * 1024 * 1024 then
    Bad(jpegUnsupportedImageSize);
  FillChar(QuantValid, SizeOf(QuantValid), 0);
  FillChar(DC, SizeOf(DC), 0);
  FillChar(AC, SizeOf(AC), 0);
  for var C := 0 to 2 do
    Comps[C] := Default(TComponent);
  Frame := False;
  NComp := 0;
  Restart := 0;
  Adobe := -1;
  At := 2;
  repeat
    var M := Marker;
    if M = $D9 then
      Break;
    if (M = $D8) or (M = $01) or ((M >= $D0) and (M <= $D7)) then
      Bad;
    var Start := At;
    var Size := U16;
    if (Size < 2) or (Size > Length(Data) - Start) then
      Bad(jpegBadMarkerLength);
    EndSegment := Start + Size;
    case M of
      $DB:
        QuantTable;
      $C4:
        HuffTable;
      $DD:
        begin
          if Size <> 4 then
            Bad(jpegBadMarkerLength);
          Restart := U16;
        end;
      $C0, $C1:
        begin
          FrameHeader;
          if At <> EndSegment then
            Bad(jpegBadMarkerLength);
          if HeaderOnly then
            Exit(jpegOK);
        end;
      $DA:
        begin
          Scan;
          Continue;
        end;
      $EE:
        if (EndSegment - At >= 12) and (Data[At] = Ord('A')) and (Data[At + 1] = Ord('d')) and
          (Data[At + 2] = Ord('o')) and (Data[At + 3] = Ord('b')) and (Data[At + 4] = Ord('e')) then
          Adobe := Data[At + 11];
      $E0..$ED, $EF, $FE:
        ;
    else
      Bad(jpegUnsupportedColorSpace);
    end;
    At := EndSegment;
  until False;
  if not Frame then
    Bad;
  for var C := 0 to NComp - 1 do
    if not Comps[C].Decoded then
      Bad;
  Image.ColorSpace := jpegYCbCr;
  if NComp = 1 then
    Image.ColorSpace := jpegGray
  else if (Adobe = 0) or ((Comps[0].Id = Ord('R')) and (Comps[1].Id = Ord('G')) and (Comps[2].Id = Ord('B'))) then
    Image.ColorSpace := jpegRGB
  else if Adobe > 1 then
    Bad(jpegUnsupportedColorSpace);
  for var C := 0 to NComp - 1 do
  begin
    var W := (Image.Width * Comps[C].H + HMax - 1) div HMax;
    var H := (Image.Height * Comps[C].V + VMax - 1) div VMax;
    Image.PlaneWidth[C] := W;
    Image.PlaneHeight[C] := H;
    Image.SampleH[C] := Comps[C].H;
    Image.SampleV[C] := Comps[C].V;
    SetLength(Image.Planes[C], W * H);
    var Stride := Comps[C].BlocksW * 8;
    for var Y := 0 to H - 1 do
      Move(Comps[C].Data[Y * Stride], Image.Planes[C][Y * W], W);
  end;
  Result := jpegOK;
end;

function DecodeJPEGPlanes(const Data: TBytes; HeaderOnly, Restrict420: Boolean; out Image: TJPEGPlanes; MaxPixels: Integer): TJPEGStatus;
begin
  try
    Result := ReadJPEG(Data, HeaderOnly, Restrict420, Image, MaxPixels);
  except
    on E: EJPEGDecode do
    begin
      Image := Default(TJPEGPlanes);
      Result := E.Status;
    end;
  end;
end;

function DecodeJPEG(const Data: TBytes; MaxPixels: Integer): TRasterImage;
var
  Image: TJPEGPlanes;

  function Sample(C, X, Y: Integer): Integer;

    function Floor256(Value: Integer): Integer;
    begin
      if Value >= 0 then
        Result := Value div 256
      else
        Result := -((-Value + 255) div 256);
    end;

  begin
    var PX := ((2 * X + 1) * Image.SampleH[C] * 128 div Image.MaxH) - 128;
    var PY := ((2 * Y + 1) * Image.SampleV[C] * 128 div Image.MaxV) - 128;
    var X0 := Floor256(PX);
    var Y0 := Floor256(PY);
    var FX := PX - X0 * 256;
    var FY := PY - Y0 * 256;
    var W := Image.PlaneWidth[C];
    var H := Image.PlaneHeight[C];
    var X1 := EnsureRange(X0 + 1, 0, W - 1);
    var Y1 := EnsureRange(Y0 + 1, 0, H - 1);
    X0 := EnsureRange(X0, 0, W - 1);
    Y0 := EnsureRange(Y0, 0, H - 1);
    Result := (Image.Planes[C][Y0 * W + X0] * (256 - FX) * (256 - FY) + Image.Planes[C][Y0 * W + X1] * FX * (256 - FY) +
      Image.Planes[C][Y1 * W + X0] * (256 - FX) * FY + Image.Planes[C][Y1 * W + X1] * FX * FY + 32768) shr 16;
  end;

  function Rounded(Value: Integer): Integer;
  begin
    Inc(Value, 32768);
    if Value >= 0 then
      Result := Value div 65536
    else
      Result := -((-Value + 65535) div 65536);
  end;

begin
  var Status := DecodeJPEGPlanes(Data, False, False, Image, MaxPixels);
  if Status = jpegUnsupportedImageSize then
    raise EImageResourceLimit.Create('JPEG pixel/plane limit');
  if Status <> jpegOK then
    raise EImageFormat.Create('JPEG invalid/unsupported coding: ' + IntToStr(Ord(Status)));
  Result.Width := Image.Width;
  Result.Height := Image.Height;
  SetLength(Result.Pixels, Image.Width * Image.Height);
  for var Y := 0 to Image.Height - 1 do
    for var X := 0 to Image.Width - 1 do
    begin
      var R := Sample(0, X, Y);
      var G := R;
      var B := R;
      if Image.Components = 3 then
      begin
        var C1 := Sample(1, X, Y);
        var C2 := Sample(2, X, Y);
        if Image.ColorSpace = jpegRGB then
        begin
          G := C1;
          B := C2;
        end
        else
        begin
          var L := R;
          Dec(C1, 128);
          Dec(C2, 128);
          R := L + Rounded(91881 * C2);
          G := L - Rounded(22554 * C1 + 46802 * C2);
          B := L + Rounded(116130 * C1);
        end;
      end;
      Result.Pixels[Y * Image.Width + X] := $FF000000 or (UInt32(EnsureRange(R, 0, 255)) shl 16) or
        (UInt32(EnsureRange(G, 0, 255)) shl 8) or UInt32(EnsureRange(B, 0, 255));
    end;
end;

end.

