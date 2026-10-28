unit PSP.Mpeg;

{$Q-}{$R-}{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, PSP.Memory, PSP.CPU,
  PSP.Kernel, PSP.MpegStream, Video.AVC.Types, Video.AVC.H264, Audio.ATRAC3Plus;

type
  TPSPMpegContext = class
    Handle, Ring, PixelMode, Width, Frames, ExpectedBytes, ReceivedBytes: Cardinal;
    ES: array[1..2] of Boolean;
    Streams: TDictionary<Cardinal, Cardinal>;
    Demux: TPSPMpegStream;
    Decoder: TH264Decoder;
    DecoderOwner: IVideoDecoder;
    Audio: TATRAC3PlusDecoder;
    AudioChannels: Integer;
    VideoEndPTS, AudioEndPTS: Int64;
    VideoAttribute: Cardinal;
    ExpectedVideoFrames, SubmittedVideoFrames, ReceivedVideoFrames: Cardinal;
    FirstVideoPTS: Int64;
    VideoAU, AudioAU: TMediaPacket;
    HasVideo, HasAudio, InputEOF, VideoDrain, FrameReady, ClockInitialized: Boolean;
    Frame: TVideoFrame;
    function ReceiveFrame: Boolean;
    procedure SendVideo;
    constructor Create;
    destructor Destroy; override;
  end;

  TPSPMpeg = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FKernel: TPSPKernel;
    FContexts: TObjectDictionary<Cardinal, TPSPMpegContext>;
    FNextStream: Cardinal;
    FLastVideoPacket: TBytes;
    function Context(Address: Cardinal): TPSPMpegContext;
    function Bytes(Address, Size: Cardinal): TBytes;
    function Available(Ring: Cardinal): Cardinal;
    procedure WriteAU(Address: Cardinal; const Packet: TMediaPacket);
    procedure WriteFrame(const Frame: TVideoFrame; Destination, Stride, Mode: Cardinal);
    procedure PutNext(Ring, Remaining, Written: Cardinal);
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
    destructor Destroy; override;
    function Handle(NID: Cardinal; out Value: Cardinal): Boolean;
    function DescribeContexts: string;
    property LastVideoPacket: TBytes read FLastVideoPacket;
  end;

implementation

uses
  PSP.YCbCr;

const
  NoData = $80618001;
  InvalidValue = $806101FE;
  NoMemory = $80610022;

function TPSPMpegContext.ReceiveFrame: Boolean;
begin
  var Decoded: TVideoFrame;
  Result := Decoder.Receive(Decoded);
 // An empty receive must not erase the dimensions or picture retained for
 // sceMpegAvcDecodeDetail. Only a successful decode replaces that state.
  if Result then
  begin
    // PSMF publishes the display clock. PES timestamps describe only the first
    // AU in a packet; estimated per-AU stamps can repeat at a PES boundary.
    // Count pictures actually released by the reorder queue, including drains.
    if ClockInitialized then
      Decoded.PTS := FirstVideoPTS + Int64(ReceivedVideoFrames) * 3003;
    Inc(ReceivedVideoFrames);
    Frame := Decoded;
    VideoEndPTS := Max(VideoEndPTS, Decoded.PTS + Decoded.Duration);
  end;
end;

procedure TPSPMpegContext.SendVideo;
begin
  if not ClockInitialized then
  begin
    if ExpectedVideoFrames = 0 then
      FirstVideoPTS := Max(VideoAU.PTS, 0);
    ClockInitialized := True;
  end;
  Decoder.SendAnnexB(VideoAU);
  Inc(SubmittedVideoFrames);
end;

constructor TPSPMpegContext.Create;
begin
  inherited;
  Demux := TPSPMpegStream.Create;
  Decoder := TH264Decoder.Create;
  DecoderOwner := Decoder;
  // PSMF has sparse PES timestamps. H.264 picture order determines display
  // order; the firmware service supplies the continuous presentation clock.
  Decoder.ConfigureAnnexB(True);
  Streams := TDictionary<Cardinal, Cardinal>.Create;
  PixelMode := 3;
end;

destructor TPSPMpegContext.Destroy;
begin
  Audio.Free;
  DecoderOwner := nil;
  Demux.Free;
  Streams.Free;
  inherited
end;

constructor TPSPMpeg.Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
begin
  inherited Create;
  FMemory := Memory;
  FCPU := CPU;
  FKernel := Kernel;
  FContexts := TObjectDictionary<Cardinal, TPSPMpegContext>.Create([doOwnsValues]);
  FNextStream := 1
end;

destructor TPSPMpeg.Destroy;
begin
  FContexts.Free;
  inherited
end;

function TPSPMpeg.DescribeContexts: string;
begin
  Result := '';
  for var Ctx in FContexts.Values do
    Result := Result + Format('MPEG %8.8x frames=%d input=%d/%d eof=%s retained=%d video=%s drain=%s audio=%s pts=%d end=%d aus=%d/%d audio_end=%d' + sLineBreak,
      [Ctx.Handle, Ctx.Frames, Ctx.ReceivedBytes, Ctx.ExpectedBytes, BoolToStr(Ctx.InputEOF, True), Ctx.Demux.RetainedBytes,
        BoolToStr(Ctx.HasVideo, True), BoolToStr(Ctx.VideoDrain, True), BoolToStr(Ctx.HasAudio, True), Ctx.Frame.PTS,
        Ctx.VideoEndPTS, Ctx.SubmittedVideoFrames, Ctx.ExpectedVideoFrames, Ctx.AudioEndPTS]);
end;

function TPSPMpeg.Context(Address: Cardinal): TPSPMpegContext;
begin
  Result := nil;
  if FMemory.IsValid(Address, 4) then
    FContexts.TryGetValue(FMemory.Read32(Address), Result);
end;

function TPSPMpeg.Bytes(Address, Size: Cardinal): TBytes;
begin
  if (Size > 16 * 1024 * 1024) or not FMemory.IsValid(Address, Size) then
    raise EPSPMemory.Create('PSP MPEG invalid input range');
  Result := FMemory.ReadBytes(Address, Size);
end;

procedure TPSPMpeg.WriteAU(Address: Cardinal; const Packet: TMediaPacket);
begin
  FMemory.Write32(Address, Cardinal(UInt64(Packet.PTS) shr 32));
  FMemory.Write32(Address + 4, Cardinal(Packet.PTS));
  FMemory.Write32(Address + 8, Cardinal(UInt64(Packet.DTS) shr 32));
  FMemory.Write32(Address + 12, Cardinal(Packet.DTS));
  FMemory.Write32(Address + 20, Length(Packet.Data));
end;

procedure TPSPMpeg.WriteFrame(const Frame: TVideoFrame; Destination, Stride, Mode: Cardinal);
begin
  if (Frame.Width <= 0) or (Frame.Height <= 0) then
    Exit;
  if Stride = 0 then
    Stride := Frame.Width;
  var PixelSize := 2;
  if Mode = 3 then
    PixelSize := 4;
  if (Stride < Cardinal(Frame.Width)) or (Stride > 2048) or not FMemory.IsValid(Destination, Stride * Cardinal(Frame.Height) * Cardinal(PixelSize)) then
    raise EPSPMemory.Create('PSP MPEG invalid framebuffer range');
  var Row: TBytes;
  SetLength(Row, Frame.Width * PixelSize);
  for var Y := 0 to Frame.Height - 1 do
  begin
    for var X := 0 to Frame.Width - 1 do
    begin
      var L := Max(0, Integer(Frame.Planes[0][Y * Frame.Strides[0] + X]) - 16) * 298;
      var U := Integer(Frame.Planes[1][(Y div 2) * Frame.Strides[1] + X div 2]) - 128;
      var V := Integer(Frame.Planes[2][(Y div 2) * Frame.Strides[2] + X div 2]) - 128;
      var R := Cardinal(EnsureRange((L + 409 * V + 128) shr 8, 0, 255));
      var G := Cardinal(EnsureRange((L - 100 * U - 208 * V + 128) shr 8, 0, 255));
      var B := Cardinal(EnsureRange((L + 516 * U + 128) shr 8, 0, 255));
   // Signed arithmetic division must round down, not Delphi's logical SHR.
      if L + 409 * V + 128 < 0 then
        R := 0;
      if L - 100 * U - 208 * V + 128 < 0 then
        G := 0;
      if L + 516 * U + 128 < 0 then
        B := 0;
      var At := @Row[X * PixelSize];
      case Mode of
        0:
          PWord(At)^ := (R shr 3) or ((G shr 2) shl 5) or ((B shr 3) shl 11);
        1:
          PWord(At)^ := $8000 or (R shr 3) or ((G shr 3) shl 5) or ((B shr 3) shl 10);
        2:
          PWord(At)^ := $F000 or (R shr 4) or ((G shr 4) shl 4) or ((B shr 4) shl 8);
        3:
          PCardinal(At)^ := $FF000000 or R or (G shl 8) or (B shl 16);
      end;
    end;
    FMemory.Load(Destination + Cardinal(Y) * Stride * Cardinal(PixelSize), Row);
  end;
end;

function TPSPMpeg.Available(Ring: Cardinal): Cardinal;
begin
  var Capacity := FMemory.Read32(Ring);
  var Ctx := Context(FMemory.Read32(Ring + 40));
  if Ctx = nil then
    Exit(Capacity - FMemory.Read32(Ring + 12));
  // Get*Au copies data into independently owned ES storage. Pending decode
  // work and partial elementary frames no longer retain the source ring.
  var Retained := Ctx.Demux.RingRetainedBytes;
  var Used := Min(Capacity, Cardinal((Retained + 2047) div 2048));
  FMemory.Write32(Ring + 12, Used);
  Result := Capacity - Used;
end;

procedure TPSPMpeg.PutNext(Ring, Remaining, Written: Cardinal);
begin
  if Remaining = 0 then
  begin
    FKernel.CompleteDevice(6, Ring, Written);
    Exit
  end;
  var Capacity := FMemory.Read32(Ring);
  var Position := FMemory.Read32(Ring + 8) mod Capacity;
  var Count := Min(Remaining, Capacity - Position);
  var Address := FMemory.Read32(Ring + 20) + Position * 2048;
  var Callback := FMemory.Read32(Ring + 24);
  var Argument := FMemory.Read32(Ring + 28);
  FKernel.QueueCall(Callback, Address, Count, Argument, False,
    procedure
    begin
      var Actual := Integer(FKernel.LastCallResult);
      {$IFDEF PSP_TRACE_MPEG_RING}
      Writeln('MPEG ring ', IntToHex(Ring, 8), ' position=', Position, ' request=', Count, ' actual=', Actual,
        ' first=', IntToHex(FMemory.Read32(Address), 8), IntToHex(FMemory.Read32(Address + 4), 8), IntToHex(FMemory.Read32(Address + 8), 8));
      {$ENDIF}
      if Actual < 0 then
      begin
        FKernel.CompleteDevice(6, Ring, Cardinal(Actual));
        Exit
      end;
      Actual := Min(Actual, Integer(Count));
      var Ctx := Context(FMemory.Read32(Ring + 40));
      if (Actual > 0) and (Ctx <> nil) then
      begin
        Ctx.Demux.Feed(Bytes(Address, Cardinal(Actual) * 2048));
        Inc(Ctx.ReceivedBytes, Cardinal(Actual) * 2048);
        if (Ctx.ExpectedBytes <> 0) and (Ctx.ReceivedBytes >= Ctx.ExpectedBytes) then
        begin
          Ctx.Demux.Flush;
          Ctx.InputEOF := True
        end;
      end;
      // A callback may supply zero packets while its asynchronous reader is
      // still filling the source. This is starvation, not an end-of-stream
      // marker: flushing here splits incomplete NALs and drains live pictures.
      FMemory.Write32(Ring + 4, FMemory.Read32(Ring + 4) + Cardinal(Actual));
      FMemory.Write32(Ring + 8, FMemory.Read32(Ring + 8) + Cardinal(Actual));
      FMemory.Write32(Ring + 12, 0);
      if Actual < Integer(Count) then
        FKernel.CompleteDevice(6, Ring, Written + Cardinal(Actual))
      else
        PutNext(Ring, Remaining - Cardinal(Actual), Written + Cardinal(Actual));
    end);
  FKernel.AcceptCallbacks;
end;

function TPSPMpeg.Handle(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  var E := FCPU.Registers[8];
  var F := FCPU.Registers[9];
  var Ctx := Context(A);
 {$IFDEF PSP_TRACE_MPEG}      Writeln('mpeg ', IntToHex(NID, 8), ' ', IntToHex(A, 8), ' ', IntToHex(B, 8), ' ', IntToHex(C, 8), ' ', IntToHex(D, 8));{$ENDIF}
  case NID of
    $682A619B, $874624D6:
      ; // Native service lifecycle owns codec state.
      $C132E22F:
      Value := $10000;
    $D7A29F46:
      if A > $100000 then
        Value := NoMemory
      else
        Value := A * 2152;
    $769BEBB6:
      Value := A div 2152;
    $37295ED8:
      begin
        if (B = 0) or (B > $100000) or (UInt64(B) * 2152 > D) then
        begin
          Value := NoMemory;
          Exit
        end;
        if not FMemory.IsValid(C, B * 2048) or not FMemory.IsValid(A, 48) then
        begin
          Value := InvalidValue;
          Exit
        end;
        FMemory.Zero(A, 48);
        FMemory.Write32(A, B);
        FMemory.Write32(A + 16, 2048);
        FMemory.Write32(A + 20, C);
        FMemory.Write32(A + 24, E);
        FMemory.Write32(A + 28, F);
        FMemory.Write32(A + 32, C + B * 2048);
        FMemory.Write32(A + 44, FCPU.Registers[28]);
      end;
    $13407F13:
      ;
    $D8C5F121:
      begin
        if C < $10000 then
        begin
          Value := NoMemory;
          Exit
        end;
        var Handle := B + $30;
        FMemory.Zero(Handle, 32);
        FMemory.Load(Handle, TEncoding.ASCII.GetBytes('LIBMPEG'#0'001'#0));
        FMemory.Write32(A, Handle);
        FMemory.Write32(Handle + 12, $FFFFFFFF);
        FMemory.Write32(Handle + 16, D);
        if D <> 0 then
          FMemory.Write32(D + 40, A);
        var NewContext := TPSPMpegContext.Create;
        NewContext.Handle := Handle;
        NewContext.Ring := D;
        NewContext.Width := E;
        FContexts.AddOrSetValue(Handle, NewContext);
      end;
    $606A4649:
      if Ctx = nil then
        Value := InvalidValue
      else
        FContexts.Remove(Ctx.Handle);
    $21FF80E4, $611E9E11:
      begin
        var Header := B;
        var Output := C;
        var Field: Cardinal := 8;
        if NID = $611E9E11 then
        begin
          Header := A;
          Output := B;
          Field := 12
        end;
        FMemory.Write32(Output, 0);
        if FMemory.Read32(Header) <> $464D5350 then
        begin
          Value := InvalidValue;
          Exit
        end;
        var Size: Cardinal := 0;
        for var I := 0 to 3 do
          Size := (Size shl 8) or FMemory.Read8(Header + Field + Cardinal(I));
        if Size and 2047 <> 0 then
          Value := InvalidValue
        else
          FMemory.Write32(Output, Size);
        if (NID = $21FF80E4) and (Ctx <> nil) then
        begin
          Ctx.ExpectedBytes := 0;
          Ctx.ReceivedBytes := 0;
          Ctx.InputEOF := False;
          for var I := 0 to 3 do
            Ctx.ExpectedBytes := (Ctx.ExpectedBytes shl 8) or FMemory.Read8(Header + 12 + Cardinal(I));
          Ctx.ExpectedVideoFrames := 0;
          Ctx.SubmittedVideoFrames := 0;
          Ctx.ReceivedVideoFrames := 0;
          Ctx.ClockInitialized := False;
          if FMemory.IsValid(Header, 96) then
          begin
            var FirstPTS, LastPTS: UInt64;
            FirstPTS := 0;
            LastPTS := 0;
            for var I := 0 to 5 do
            begin
              FirstPTS := (FirstPTS shl 8) or FMemory.Read8(Header + $54 + Cardinal(I));
              LastPTS := (LastPTS shl 8) or FMemory.Read8(Header + $5A + Cardinal(I));
            end;
            // The native PSP video clock currently uses 3003 ticks per AU.
            // Use an exact header duration only; audio padding may continue
            // after the final video AU and need not be read by the application.
            if (LastPTS > FirstPTS) and ((LastPTS - FirstPTS) mod 3003 = 0) and
              ((LastPTS - FirstPTS) div 3003 <= High(Cardinal)) then
            begin
              Ctx.ExpectedVideoFrames := (LastPTS - FirstPTS) div 3003;
              Ctx.FirstVideoPTS := FirstPTS;
            end;
          end;
        end;
      end;
    $B5F6DC87:
      Value := Available(A);
    $B240A59E:
      begin
        var Count := Min(Integer(B), Integer(C));
        Count := Min(Count, Integer(Available(A)));
        if Count <= 0 then
          Exit;
        if FMemory.Read32(A + 24) = 0 then
        begin
          Value := InvalidValue;
          Exit
        end;
        FKernel.WaitDevice(6, A);
        PutNext(A, Count, 0);
      end;
    $42560F23:
      if Ctx = nil then
        Value := InvalidValue
      else
      begin
        Value := FNextStream;
        Inc(FNextStream);
        Ctx.Streams.Add(Value, B);
      end;
    $591A4AA2:
      if Ctx = nil then
        Value := InvalidValue
      else
        Ctx.Streams.Remove(B);
    $A780CF7E:
      begin
        if Ctx = nil then
        begin
          Value := InvalidValue;
          Exit
        end;
        for var I := 1 to 2 do
          if not Ctx.ES[I] then
          begin
            Ctx.ES[I] := True;
            Value := I;
            Break
          end;
      end;
    $CEB870B1:
      if (Ctx = nil) or not (B in [1, 2]) then
        Value := InvalidValue
      else
        Ctx.ES[B] := False;
    $167AFD9E:
      begin
        if Ctx = nil then
        begin
          Value := InvalidValue;
          Exit
        end;
        FMemory.Zero(C, 24);
        FMemory.Write32(C + 16, B);
        if B in [1, 2] then
          FMemory.Write32(C + 20, 2048)
        else
        begin
          FMemory.Write32(C + 8, $FFFFFFFF);
          FMemory.Write32(C + 12, $FFFFFFFF);
          FMemory.Write32(C + 20, 2112)
        end;
      end;
    $F8DCB679:
      begin
        FMemory.Write32(B, 2112);
        FMemory.Write32(C, 8192)
      end;
    $C02CF6B5:
      begin
        FMemory.Write32(B, 320);
        FMemory.Write32(C, 320)
      end;
    $FE246728, $E1CE83A7:
      begin
        if (Ctx = nil) or not Ctx.Streams.ContainsKey(B) then
        begin
          Value := InvalidValue;
          Exit
        end;
        if not FMemory.IsValid(C, 24) then
        begin
          Value := InvalidValue;
          Exit
        end;
        var IsVideo := NID = $FE246728;
        if IsVideo then
        begin
          if not Ctx.HasVideo then
          begin
            Ctx.HasVideo := Ctx.Demux.ReceiveVideo(Ctx.VideoAU);
            if Ctx.HasVideo then
              Ctx.VideoAttribute := Ctx.Demux.LastVideoAttribute;
          end;
          var VideoEOF := Ctx.InputEOF or ((Ctx.ExpectedVideoFrames <> 0) and
            (Ctx.SubmittedVideoFrames >= Ctx.ExpectedVideoFrames));
          if not Ctx.HasVideo and VideoEOF then
          begin
       // Delayed B pictures still belong to this stream. Publish each one
       // before reporting NO_DATA, so clients can reach their final timestamp.
            Ctx.Decoder.Flush;
            Ctx.VideoDrain := Ctx.ReceiveFrame;
            Ctx.HasVideo := Ctx.VideoDrain;
            if Ctx.VideoDrain then
            begin
              Ctx.VideoAU := Default(TMediaPacket);
              Ctx.VideoAU.PTS := Ctx.Frame.PTS;
              Ctx.VideoAU.DTS := Ctx.Frame.PTS;
              Ctx.VideoAttribute := 1
            end;
          end;
          if not Ctx.HasVideo then
          begin
            if VideoEOF then
            begin
              FMemory.Write32(C, Cardinal(UInt64(Ctx.VideoEndPTS) shr 32));
              FMemory.Write32(C + 4, Cardinal(Ctx.VideoEndPTS));
              FMemory.Write32(C + 8, $FFFFFFFF);
              FMemory.Write32(C + 12, $FFFFFFFF);
            end;
            Value := NoData;
            Exit
          end;
          WriteAU(C, Ctx.VideoAU);
        end
        else
        begin
          if not Ctx.HasAudio then
            Ctx.HasAudio := Ctx.Demux.ReceiveAudio(Ctx.AudioAU);
          if not Ctx.HasAudio then
          begin
            if Ctx.InputEOF then
            begin
              FMemory.Write32(C, Cardinal(UInt64(Ctx.AudioEndPTS) shr 32));
              FMemory.Write32(C + 4, Cardinal(Ctx.AudioEndPTS));
              FMemory.Write32(C + 8, $FFFFFFFF);
              FMemory.Write32(C + 12, $FFFFFFFF);
            end;
            Value := NoData;
            Exit
          end;
          WriteAU(C, Ctx.AudioAU);
        end;
        if FMemory.IsValid(D, 4) then
          if IsVideo then
            FMemory.Write32(D, Ctx.VideoAttribute)
          else
            FMemory.Write32(D, 0);
      end;
    $211A057C:
      begin
        if (Ctx = nil) or not FMemory.IsValid(E, 4) then
        begin
          Value := InvalidValue;
          Exit
        end;
        FMemory.Write32(E, 0);
        var Size := PSPYCbCrSize(B, C, D);
        if Size = 0 then
          Value := InvalidValue
        else
          FMemory.Write32(E, Size);
      end;
    $67179B1B:
      begin
        if (Ctx = nil) or (PSPYCbCrSize(B, C, D) = 0) then
        begin
          Value := InvalidValue;
          Exit
        end;
        InitPSPYCbCr(FMemory, E, B, C, D);
      end;
    $F0EB1125:
      begin
        if (Ctx = nil) or not Ctx.HasVideo then
        begin
          Value := NoData;
          Exit
        end;
        if not FMemory.IsValid(C, 4) or not FMemory.IsValid(D, 4) then
        begin
          Value := InvalidValue;
          Exit
        end;
        var Ready := Ctx.VideoDrain;
        if not Ready then
        begin
          FLastVideoPacket := Ctx.VideoAU.Data;
          Ctx.SendVideo;
          Ready := Ctx.ReceiveFrame
        end;
        Ctx.HasVideo := False;
        Ctx.VideoDrain := False;
        Ctx.FrameReady := Ready;
        if Ready then
        begin
          FMemory.Write32(B, Cardinal(UInt64(Ctx.Frame.PTS) shr 32));
          FMemory.Write32(B + 4, Cardinal(Ctx.Frame.PTS));
        end;
        if Ready then
        begin
          WritePSPYCbCr(FMemory, FMemory.Read32(C), Ctx.Frame);
          Inc(Ctx.Frames)
        end;
        FMemory.Write32(D, Ord(Ready));
        FKernel.WaitUntil(FKernel.Time + 3300);
      end;
    $F2930C9C:
      begin
        if (Ctx = nil) or not FMemory.IsValid(C, 4) then
        begin
          Value := InvalidValue;
          Exit
        end;
        Ctx.Decoder.Flush;
        var Ready := Ctx.ReceiveFrame;
        Ctx.FrameReady := Ready;
        if Ready and (B <> 0) then
          WritePSPYCbCr(FMemory, FMemory.Read32(B), Ctx.Frame);
        FMemory.Write32(C, Ord(Ready));
      end;
    $0558B075:
      begin
        if Ctx = nil then
        begin
          Value := InvalidValue;
          Exit
        end;
        var Frame := ReadPSPYCbCr(FMemory, C);
        WritePSPYCbCr(FMemory, B, Frame);
      end;
    $31BD0272:
      begin
        if (Ctx = nil) or not FMemory.IsValid(C, 16) then
        begin
          Value := InvalidValue;
          Exit
        end;
        var Frame := ReadPSPYCbCr(FMemory, B);
        var X := FMemory.Read32(C);
        var Y := FMemory.Read32(C + 4);
        var W := FMemory.Read32(C + 8);
        var H := FMemory.Read32(C + 12);
        if ((X or Y or W or H) and 15 <> 0) or (W = 0) or (H = 0) or
          (UInt64(X) + W > Cardinal(Frame.Width)) or (UInt64(Y) + H > Cardinal(Frame.Height)) then
        begin
          Value := InvalidValue;
          Exit
        end;
        if (X <> 0) or (Y <> 0) or (W <> Cardinal(Frame.Width)) or (H <> Cardinal(Frame.Height)) then
        begin
          var Crop := Default(TVideoFrame);
          Crop.Width := W;
          Crop.Height := H;
          for var Plane := 0 to 2 do
          begin
            var Scale := 1;
            if Plane <> 0 then
              Scale := 2;
            var PW := Integer(W) div Scale;
            var PH := Integer(H) div Scale;
            Crop.Strides[Plane] := PW;
            SetLength(Crop.Planes[Plane], PW * PH);
            for var Row := 0 to PH - 1 do
              Move(Frame.Planes[Plane][(Integer(Y) div Scale + Row) * Frame.Strides[Plane] + Integer(X) div Scale], Crop.Planes[Plane][Row * PW], PW);
          end;
          Frame := Crop;
        end;
        if D = 0 then
          D := Ctx.Width;
        WriteFrame(Frame, E, D, Ctx.PixelMode);
        FKernel.WaitUntil(FKernel.Time + 1000);
      end;
    $A11C7026:
      begin
        if Ctx = nil then
        begin
          Value := InvalidValue;
          Exit
        end;
        var Mode := FMemory.Read32(B + 4);
        if Mode > 3 then
          Value := InvalidValue
        else
          Ctx.PixelMode := Mode;
      end;
    $0E3C2E9D:
      begin
        if Ctx = nil then
        begin
          Value := InvalidValue;
          Exit
        end;
        if not Ctx.HasVideo then
        begin
          Value := NoData;
          Exit
        end;
        var Ready := Ctx.VideoDrain;
        if not Ready then
        begin
          FLastVideoPacket := Ctx.VideoAU.Data;
          Ctx.SendVideo;
          Ready := Ctx.ReceiveFrame
        end;
        Ctx.HasVideo := False;
        Ctx.VideoDrain := False;
        Ctx.FrameReady := Ready;
        if Ready then
        begin
          FMemory.Write32(B, Cardinal(UInt64(Ctx.Frame.PTS) shr 32));
          FMemory.Write32(B + 4, Cardinal(Ctx.Frame.PTS));
        end;
        if Ready then
        begin
          WriteFrame(Ctx.Frame, FMemory.Read32(D), C, Ctx.PixelMode);
          Inc(Ctx.Frames)
        end;
        if E <> 0 then
          FMemory.Write32(E, Ord(Ready));
        FKernel.WaitUntil(FKernel.Time + 3300);
      end;
    $800C44DF:
      begin
        if (Ctx = nil) or not Ctx.HasAudio then
        begin
          Value := NoData;
          Exit
        end;
        if (Ctx.Audio = nil) or (Ctx.AudioChannels <> Ctx.AudioAU.TrackIndex) then
        begin
          Ctx.Audio.Free;
          Ctx.AudioChannels := Ctx.AudioAU.TrackIndex;
          Ctx.Audio := TATRAC3PlusDecoder.Create(Ctx.AudioChannels, 2)
        end;
        if D <> 0 then
          Ctx.Audio.Reset;
        var Samples := Ctx.Audio.Decode(Ctx.AudioAU.Data);
        Ctx.AudioEndPTS := Max(Ctx.AudioEndPTS, Ctx.AudioAU.PTS + Ctx.AudioAU.Duration);
        Ctx.HasAudio := False;
        var Output: TBytes;
        SetLength(Output, Length(Samples) * 2);
        Move(Samples[0], Output[0], Length(Output));
        FMemory.Load(C, Output);
        FKernel.WaitUntil(FKernel.Time + 2300);
      end;
    $0F6C18D7:
      begin
        if Ctx = nil then
        begin
          Value := InvalidValue;
          Exit
        end;
        FMemory.Zero(B, 36);
        FMemory.Write32(B + 4, Ctx.Frames);
        FMemory.Write32(B + 8, Ctx.Frame.Width);
        FMemory.Write32(B + 12, Ctx.Frame.Height);
        FMemory.Write32(B + 32, Ord(Ctx.FrameReady));
      end;
    $740FCCD1:
      begin
        if Ctx = nil then
        begin
          Value := InvalidValue;
          Exit
        end;
        Ctx.Decoder.Flush;
        var Ready := Ctx.ReceiveFrame;
        Ctx.FrameReady := Ready;
        if Ready then
          WriteFrame(Ctx.Frame, FMemory.Read32(C), B, Ctx.PixelMode);
        if D <> 0 then
          FMemory.Write32(D, Ord(Ready));
      end;
    $4571CC64:
      begin
        if Ctx = nil then
        begin
          Value := InvalidValue;
          Exit
        end;
    // Drain delayed display pictures without dropping PES/AU data or reference
    // pictures. The ring may already contain the continuation of this stream.
        Ctx.Decoder.Flush;
        var Discard: TVideoFrame;
        while Ctx.Decoder.Receive(Discard) do
          ;
      end;
    $707B7629, $500F0429:
      begin
        if Ctx = nil then
        begin
          Value := InvalidValue;
          Exit
        end;
        Ctx.Decoder.Reset;
        Ctx.Demux.Free;
        Ctx.Demux := TPSPMpegStream.Create;
        Ctx.HasVideo := False;
        Ctx.HasAudio := False;
        Ctx.VideoDrain := False;
        Ctx.InputEOF := False;
        Ctx.FrameReady := False;
        Ctx.Frame := Default(TVideoFrame);
        Ctx.VideoEndPTS := 0;
        Ctx.AudioEndPTS := 0;
        Ctx.ReceivedBytes := 0;
        Ctx.SubmittedVideoFrames := 0;
        Ctx.ReceivedVideoFrames := 0;
        Ctx.ClockInitialized := False;
        if Ctx.Audio <> nil then
          Ctx.Audio.Reset;
      end;
  else
    Result := False;
  end;
end;

end.

