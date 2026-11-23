unit CHD.FLAC;

// FLAC frame decoder, following libchdr/dr_flac and the FLAC bitstream format.
// CHD supplies the stream parameters: stereo, 44100 Hz, 16-bit PCM.

interface

uses
  System.SysUtils;

function CHDFLAC(const Source: TBytes; Offset, OutputSize: Integer; BigEndian: Boolean; out Consumed: Integer; ChannelCount: Integer = 2): TBytes;

function DecodeFLACFrame(const Source: TBytes; Offset, ChannelCount, Depth, SampleRate: Integer; out Consumed: Integer): TBytes;

implementation

uses
  CHD.Common;

function DecodeFrames(const Source: TBytes; Offset, OutputSize: Integer; BigEndian: Boolean; out Consumed: Integer; ChannelCount, Depth, SampleRate: Integer; OneFrame: Boolean): TBytes;
const
  SampleWidths: array[0..7] of Integer = (0, 8, 12, -1, 16, 20, 24, 32);
  HeaderRates: array[0..11] of Integer =
    (0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000);
var
  Bits: TCHDBits;
  Channels: array[0..1] of TArray<Int64>;
  BlockSize, BlockCode, RateCode, Assignment, SampleCode, FrameStart, HeaderEnd, FrameEnd, Output, V, Extra, BPS, Kind, Wasted, Order, Method, PartitionOrder, PartitionSize, Rice, Width, Start, Precision, Shift: Integer;
  Coeff: array[0..31] of Int64;
  Q, U: UInt64;
  S, A, B, Pred, Residual: Int64;

  function SignedShift(Value: Int64; Count: Integer): Int64;
  begin
    if Count = 0 then
      Exit(Value);

    if Value >= 0 then
      Result := Value shr Count
    else
      Result := -1 - ((-1 - Value) shr Count);
  end;

  function FrameCRC(First, Last, Poly, Mask: Integer): Integer;
  begin
    Result := 0;
    for var i := First to Last - 1 do
    begin
      if Mask = 255 then
        Result := Result xor Source[i]
      else
        Result := Result xor (Integer(Source[i]) shl 8);
      for var J := 1 to 8 do
        if (Result and ((Mask + 1) div 2)) <> 0 then
          Result := ((Result shl 1) xor Poly) and Mask
        else
          Result := (Result shl 1) and Mask;
    end;
  end;

  procedure CheckSample(Value: Int64; Width: Integer);
  begin
    CHDRequire((Value >= -(Int64(1) shl (Width - 1))) and (Value < (Int64(1) shl (Width - 1))), 'FLAC sample out of range');
  end;

begin
  CHDRequire(ChannelCount in [1, 2], 'FLAC channel count');
  CHDRequire((OutputSize >= 0) and (OutputSize mod (2 * ChannelCount) = 0), 'FLAC sample size');
  Bits.Init(Source, False, Offset);
  SetLength(Result, OutputSize);
  Output := 0;
  while OneFrame or (Output < OutputSize) do
  begin
    FrameStart := Bits.BytePosition;
    CHDRequire(Bits.Read(14) = $3FFE, 'FLAC frame sync');
    CHDRequire(Bits.Read(1) = 0, 'FLAC reserved flag');
    Bits.Read(1);
    BlockCode := Bits.Read(4);
    RateCode := Bits.Read(4);
    Assignment := Bits.Read(4);
    SampleCode := Bits.Read(3);
    CHDRequire(Bits.Read(1) = 0, 'FLAC reserved bit');
    CHDRequire((Assignment = ChannelCount - 1) or ((ChannelCount = 2) and (Assignment >= 8) and (Assignment <= 10)), 'CHD FLAC channel count');
    CHDRequire((SampleCode = 0) or (SampleWidths[SampleCode] = Depth), 'FLAC sample width');

    V := Bits.Read(8);
    if V >= 128 then
    begin
      Extra := 0;
      while (V and $80) <> 0 do
      begin
        Inc(Extra);
        V := (V shl 1) and 255;
      end;
      CHDRequire((Extra >= 2) and (Extra <= 7), 'FLAC frame number');
      for var i := 1 to Extra - 1 do
        CHDRequire((Bits.Read(8) and $C0) = $80, 'FLAC UTF8 continuation');
    end;

    case BlockCode of
      1:
        BlockSize := 192;
      2..5:
        BlockSize := 576 shl (BlockCode - 2);
      6:
        BlockSize := Bits.Read(8) + 1;
      7:
        BlockSize := Bits.Read(16) + 1;
      8..15:
        BlockSize := 256 shl (BlockCode - 8);
    else
      raise ECHDError.Create(ceInvalidData, 'FLAC reserved block size');
    end;

    case RateCode of
      0..11:
        V := HeaderRates[RateCode];
      12:
        V := Integer(Bits.Read(8)) * 1000;
      13:
        V := Bits.Read(16);
      14:
        V := Integer(Bits.Read(16)) * 10;
    else
      raise ECHDError.Create(ceInvalidData, 'FLAC reserved sample rate');
    end;
    if (SampleRate <> 0) and (RateCode <> 0) then
      CHDRequire(V = SampleRate, 'FLAC sample rate changes');

    HeaderEnd := Bits.BytePosition;
    CHDRequire(Bits.Read(8) = Cardinal(FrameCRC(FrameStart, HeaderEnd, $07, $FF)), 'FLAC header CRC', ceChecksum);
    if OneFrame then
      SetLength(Result, BlockSize * ChannelCount * 2)
    else
      CHDRequire(BlockSize <= (OutputSize - Output) div (2 * ChannelCount), 'FLAC frame exceeds output');
    for var Ch := 0 to ChannelCount - 1 do
    begin
      BPS := Depth;
      if ((Assignment = 8) and (Ch = 1)) or ((Assignment = 9) and (Ch = 0)) or ((Assignment = 10) and (Ch = 1)) then
        Inc(BPS);
      CHDRequire(Bits.Read(1) = 0, 'FLAC subframe padding');
      Kind := Bits.Read(6);
      Wasted := 0;
      if Bits.Read(1) <> 0 then
      begin
        Wasted := 1;
        while Bits.Read(1) = 0 do
        begin
          Inc(Wasted);
          CHDRequire(Wasted < BPS, 'FLAC wasted bits');
        end;
      end;

      CHDRequire(Wasted < BPS, 'FLAC wasted bits');
      Dec(BPS, Wasted);
      SetLength(Channels[Ch], BlockSize);
      if Kind = 0 then
      begin
        S := Bits.ReadSigned(BPS);
        for var i := 0 to BlockSize - 1 do
          Channels[Ch][i] := S;
      end
      else if Kind = 1 then
        for var i := 0 to BlockSize - 1 do
          Channels[Ch][i] := Bits.ReadSigned(BPS)
      else
      begin
        if (Kind >= 8) and (Kind <= 12) then
          Order := Kind - 8
        else if Kind >= 32 then
          Order := Kind - 31
        else
          raise ECHDError.Create(ceInvalidData, 'FLAC reserved subframe');

        CHDRequire(Order <= BlockSize, 'FLAC predictor order');
        for var i := 0 to Order - 1 do
          Channels[Ch][i] := Bits.ReadSigned(BPS);
        Shift := 0;
        if Kind >= 32 then
        begin
          Precision := Bits.Read(4) + 1;
          CHDRequire(Precision <= 15, 'FLAC LPC precision');
          Shift := Bits.ReadSigned(5);
          for var i := 0 to Order - 1 do
            Coeff[i] := Bits.ReadSigned(Precision);
        end;

        Method := Bits.Read(2);
        CHDRequire(Method <= 1, 'FLAC residual method');
        PartitionOrder := Bits.Read(4);
        CHDRequire(BlockSize mod (1 shl PartitionOrder) = 0, 'FLAC partition size');
        PartitionSize := BlockSize shr PartitionOrder;
        CHDRequire(PartitionSize >= Order, 'FLAC partition predictor size');
        for var Part := 0 to (1 shl PartitionOrder) - 1 do
        begin
          Rice := Bits.Read(4 + Method);
          Width := -1;
          if Rice = (1 shl (4 + Method)) - 1 then
            Width := Bits.Read(5);
          Start := Part * PartitionSize;
          if Part = 0 then
            Inc(Start, Order);
          for var i := Start to (Part + 1) * PartitionSize - 1 do
          begin
            if Width >= 0 then
            begin
              if Width = 0 then
                Residual := 0
              else
                Residual := Bits.ReadSigned(Width);
            end
            else
            begin
              Q := 0;
              while Bits.Read(1) = 0 do
              begin
                Inc(Q);
                CHDRequire(Q < (UInt64(1) shl 32), 'FLAC residual too large');
              end;
              U := (Q shl Rice) or Bits.Read(Rice);
              CHDRequire(U < (UInt64(1) shl 48), 'FLAC residual too large');
              if Odd(U) then
                Residual := -Int64(U shr 1) - 1
              else
                Residual := Int64(U shr 1);
            end;
            Pred := 0;
            if Kind >= 32 then
            begin
              for var J := 0 to Order - 1 do
                Inc(Pred, Coeff[J] * Channels[Ch][i - J - 1]);
              if Shift >= 0 then
                Pred := SignedShift(Pred, Shift)
              else
                Pred := Pred * (Int64(1) shl (-Shift));
            end
            else
              case Order of
                1:
                  Pred := Channels[Ch][i - 1];
                2:
                  Pred := 2 * Channels[Ch][i - 1] - Channels[Ch][i - 2];
                3:
                  Pred := 3 * Channels[Ch][i - 1] - 3 * Channels[Ch][i - 2] + Channels[Ch][i - 3];
                4:
                  Pred := 4 * Channels[Ch][i - 1] - 6 * Channels[Ch][i - 2] + 4 * Channels[Ch][i - 3] - Channels[Ch][i - 4];
              end;
            S := Pred + Residual;
            CheckSample(S, BPS);
            Channels[Ch][i] := S;
          end;
        end;
      end;
      if Wasted > 0 then
        for var i := 0 to BlockSize - 1 do
          Channels[Ch][i] := Channels[Ch][i] * (Int64(1) shl Wasted);
    end;
    Bits.Align;
    FrameEnd := Bits.BytePosition;
    CHDRequire(Bits.Read(16) = Cardinal(FrameCRC(FrameStart, FrameEnd, $8005, $FFFF)), 'FLAC frame CRC', ceChecksum);
    for var i := 0 to BlockSize - 1 do
    begin
      A := Channels[0][i];
      B := 0;
      if ChannelCount = 2 then
        B := Channels[1][i];
      case Assignment of
        8:
          B := A - B;
        9:
          A := A + B;
        10:
          begin
            S := A * 2 + (B and 1);
            A := SignedShift(S + B, 1);
            B := SignedShift(S - B, 1);
          end;
      end;
      CheckSample(A, Depth);
      CheckSample(B, Depth);
      for var Ch := 0 to ChannelCount - 1 do
      begin
        if Ch = 0 then
          S := A
        else
          S := B;
        if Depth < 16 then
          S := S * (Int64(1) shl (16 - Depth))
        else if Depth > 16 then
          S := SignedShift(S, Depth - 16);
        if S < 0 then
          Inc(S, 65536);
        if BigEndian then
        begin
          Result[Output] := Byte(S shr 8);
          Result[Output + 1] := Byte(S and 255);
        end
        else
        begin
          Result[Output] := Byte(S and 255);
          Result[Output + 1] := Byte(S shr 8);
        end;
        Inc(Output, 2);
      end;
    end;
    if OneFrame then
      Break;
  end;
  Consumed := Bits.BytePosition - Offset;
end;

function CHDFLAC(const Source: TBytes; Offset, OutputSize: Integer; BigEndian: Boolean; out Consumed: Integer; ChannelCount: Integer): TBytes;
begin
  Result := DecodeFrames(Source, Offset, OutputSize, BigEndian, Consumed, ChannelCount, 16, 0, False);
end;

function DecodeFLACFrame(const Source: TBytes; Offset, ChannelCount, Depth, SampleRate: Integer; out Consumed: Integer): TBytes;
begin
  CHDRequire((Depth >= 4) and (Depth <= 24), 'Unsupported FLAC sample width');
  Result := DecodeFrames(Source, Offset, 0, False, Consumed, ChannelCount, Depth, SampleRate, True);
end;

end.

