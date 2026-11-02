unit PSP.MP3;

// sceMp3: MP3 playback from a stream the program feeds. Two handles; each has
// a ring of two halves inside its stream buffer (after a 1472-byte head that
// holds the tail of a frame that wraps). A half can be refilled once the
// decoder has left it. Frames are decoded with source/hardware/audio/mp3 and
// written alternately to the two halves of the PCM buffer, always stereo.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU,
  PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service, Audio.MP3.Types,
  Audio.MP3.Layer3;

type
  // One MPEG audio layer III frame at a time, keeping the bit reservoir.
  TPSPMp3FrameDecoder = class
  private
    FDecoder: TMP3Layer3Decoder;
    FReservoir: TBytes;
    FLastHeader: array[0..3] of Byte;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    // Decodes Frame (a whole frame starting at its header) into interleaved
    // stereo. Returns the samples per channel, 0 when the frame is unusable.
    function Decode(const Frame: TBytes; out PCM: TArray<SmallInt>; out Channels: Integer): Integer;
  end;

  // A layer III header as libmp3 reads it.
  TPSPMp3Header = record
    Version: Integer;      // 3 MPEG-1, 2 MPEG-2, 0 MPEG-2.5
    Bitrate: Integer;      // kbps
    SampleRate: Integer;
    Channels: Integer;
    SamplesPerFrame: Integer;
    FrameSize: Integer;
  end;

function PSPMp3ParseHeader(const H: array of Byte; out Info: TPSPMp3Header): Boolean;

type
  TPSPMp3HandleState = (mhFree, mhNoArg, mhReserved, mhLowLevel, mhInited);

  TPSPMp3Handle = class
  public
    State: TPSPMp3HandleState;
    HasArg: Boolean;
    StreamStart, StreamEnd: Int64;
    Buf, Pcm: Cardinal;
    BufSize, PcmSize: Integer;
    RingBase: Cardinal;
    Half, RingSize: Integer;
    W, R: Int64;
    WriteFile, ReadFile: Int64;
    WritePass, ReadPass: Integer;
    PassStart: TDictionary<Integer, Int64>;
    ReaderWaiting: Boolean;
    LoopNum: Integer;
    Sum: Int64;
    PcmHalf: Integer;
    Header: TPSPMp3Header;
    Decoder: TPSPMp3FrameDecoder;
    constructor Create;
    destructor Destroy; override;
    procedure ResetStream;
    function Length_: Int64; inline;
  end;

  TPSPMp3 = class(TPSPService)
  private
    FScheduler: TPSPScheduler;
    FHandles: array[0..1] of TPSPMp3Handle;
    FResource: Boolean;
    function Lookup(Index: Integer; out H: TPSPMp3Handle; Ready, Inited: Cardinal): Boolean;
    procedure ShortWait(Us: Integer; Result: Cardinal);
    function Writable(H: TPSPMp3Handle; out Dst: Cardinal; out SrcPos: Int64): Integer;
    function ReadRing(H: TPSPMp3Handle; Pos: Int64; Count: Integer): TBytes;
    function NextPass(H: TPSPMp3Handle): Boolean;
    function DecodeOne(H: TPSPMp3Handle; out Bytes: Integer): Cardinal;
    procedure hReserve;
    procedure hRelease;
    procedure hInitResource;
    procedure hTermResource;
    procedure hInit;
    procedure hDecode;
    procedure hNotifyAdd;
    procedure hGetInfoToAdd;
    procedure hCheckNeeded;
    procedure hResetPlayPosition;
    procedure hResetPlayPositionByFrame;
    procedure hGetSumDecoded;
    procedure hSetLoopNum;
    procedure hGetLoopNum;
    procedure hGetChannelNum;
    procedure hGetBitRate;
    procedure hGetMaxOutputSample;
    procedure hGetSamplingRate;
    procedure hGetMPEGVersion;
    procedure hGetFrameNum;
    procedure hLowLevelInit;
    procedure hLowLevelDecode;
    procedure hZero;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

implementation

uses
  System.Classes, System.Math, Audio.MP3.Frame, Audio.MP3.BitStream;

const
  ERROR_MP3_INVALID_HANDLE = Cardinal($80671001);
  ERROR_MP3_INVALID_ADDRESS = Cardinal($80671002);
  ERROR_MP3_INVALID_PARAMETER = Cardinal($80671003);
  ERROR_MP3_UNRESERVED_HANDLE = Cardinal($80671102);
  ERROR_MP3_NOT_YET_INIT_HANDLE = Cardinal($80671103);
  ERROR_MP3_NO_RESOURCE_AVAIL = Cardinal($80671201);
  ERROR_MP3_UNSUPPORTED_VERSION = Cardinal($80671301);
  ERROR_MP3_UNSUPPORTED_RATE = Cardinal($80671302);
  ERROR_MP3_DECODE_NEED_DATA = Cardinal($80671402);
  ERROR_MP3_BAD_RESET_FRAME = Cardinal($80671501);
  ERROR_AVCODEC_INVALID_DATA = Cardinal($807F00FD);

  // The stream buffer starts with room for the part of a frame that wraps.
  RingHead = 1472;
  // Init looks this far for the first header.
  SyncSearch = 1440;
  PcmSlot = 4608;

  Mpeg1Bitrates: array[1..14] of Integer = (32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320);
  Mpeg2Bitrates: array[1..14] of Integer = (8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160);
  Mpeg1Rates: array[0..2] of Integer = (44100, 48000, 32000);

// Guest addresses wrap at 4 GB, as the CPU's address arithmetic does.
function GuestAdd(Base: Cardinal; Offset: Int64): Cardinal; inline;
begin
  Result := Cardinal((Int64(Base) + Offset) and $FFFFFFFF);
end;

function PSPMp3ParseHeader(const H: array of Byte; out Info: TPSPMp3Header): Boolean;
begin
  Info := Default(TPSPMp3Header);
  Result := False;
  if (H[0] <> $FF) or ((H[1] and $E0) <> $E0) then
    Exit;
  var Version := (H[1] shr 3) and 3;
  var Layer := (H[1] shr 1) and 3;
  var BR := H[2] shr 4;
  var SR := (H[2] shr 2) and 3;
  if (Layer <> 1) or (Version = 1) or (BR = 0) or (BR = 15) or (SR = 3) then
    Exit;
  Info.Version := Version;
  var Rate := Mpeg1Rates[SR];
  if Version = 3 then
  begin
    Info.Bitrate := Mpeg1Bitrates[BR];
    Info.SamplesPerFrame := 1152;
  end
  else
  begin
    Info.Bitrate := Mpeg2Bitrates[BR];
    Info.SamplesPerFrame := 576;
    Rate := Rate div 2;
    if Version = 0 then
      Rate := Rate div 2;
  end;
  Info.SampleRate := Rate;
  if (H[3] shr 6) = 3 then
    Info.Channels := 1
  else
    Info.Channels := 2;
  Info.FrameSize := Info.SamplesPerFrame div 8 * Info.Bitrate * 1000 div Rate + ((H[2] shr 1) and 1);
  Result := True;
end;

{ TPSPMp3FrameDecoder }

constructor TPSPMp3FrameDecoder.Create;
begin
  inherited Create;
  FDecoder := TMP3Layer3Decoder.Create;
end;

destructor TPSPMp3FrameDecoder.Destroy;
begin
  FDecoder.Free;
  inherited;
end;

procedure TPSPMp3FrameDecoder.Reset;
begin
  FDecoder.Free;
  FDecoder := TMP3Layer3Decoder.Create;
  FReservoir := nil;
  FillChar(FLastHeader, SizeOf(FLastHeader), 0);
end;

function TPSPMp3FrameDecoder.Decode(const Frame: TBytes; out PCM: TArray<SmallInt>; out Channels: Integer): Integer;
begin
  Result := 0;
  PCM := nil;
  Channels := 2;
  var Info: TPSPMp3Header;
  if (Length(Frame) < 4) or not PSPMp3ParseHeader(Frame, Info) then
    Exit;
  Channels := Info.Channels;
  Result := Info.SamplesPerFrame;
  SetLength(PCM, Result * 2);
  var Bytes := Copy(Frame);
  if Length(Bytes) < Info.FrameSize then
    SetLength(Bytes, Info.FrameSize);
  var Stream := TBytesStream.Create(Bytes);
  try
    var Header: TMP3FrameHeader;
    if not TMP3FrameParser.ParseHeader(Stream, Header) or (Stream.Position <> 4) then
      Exit;
    if HDR_IS_CRC(Header.Hdr) then
      Stream.Position := Stream.Position + 2;
    var SideSize := TMP3FrameParser.SideInfoSize(Header);
    if Stream.Position + SideSize > Length(Bytes) then
      Exit;
    var SideBytes: TBytes;
    SetLength(SideBytes, SideSize);
    Stream.ReadBuffer(SideBytes[0], SideSize);
    var Side: TMP3SideInfo;
    var Bits := TMP3BitStream.Create(SideBytes);
    var Valid: Boolean;
    try
      Valid := TMP3FrameParser.ParseSideInfo(Bits, Header, Side);
    finally
      Bits.Free;
    end;
    var Main := Copy(Bytes, Integer(Stream.Position), Length(Bytes) - Integer(Stream.Position));
    if Valid then
    begin
      if (FLastHeader[0] <> 0) and (((FLastHeader[1] xor Header.hdr[1]) and $FE <> 0) or ((FLastHeader[2] xor
        Header.hdr[2]) and $0C <> 0)) then
      begin
        FReservoir := nil;
        FDecoder.Free;
        FDecoder := TMP3Layer3Decoder.Create;
      end;
      Move(Header.hdr, FLastHeader, 4);
      var Sum := 0;
      for var G := 0 to Ord(HDR_TEST_MPEG1(Header.hdr)) do
        for var Ch := 0 to Header.Channels - 1 do
          Inc(Sum, Side.Granules[G, Ch].Part2_3_Length);
      if (Side.MainDataBegin <= Length(FReservoir)) and (Sum <= (Side.MainDataBegin + Length(Main)) * 8) then
      begin
        var Input := Copy(FReservoir, Length(FReservoir) - Side.MainDataBegin, Side.MainDataBegin) + Main;
        SetLength(Input, Length(Input) + 16);
        var L, R: TArray<Single>;
        try
          FDecoder.DecodeFrame(Header, Side, Input, 0, L, R);
          for var I := 0 to Min(High(L), Result - 1) do
          begin
            PCM[I * 2] := EnsureRange(Round(L[I] * 32768), -32768, 32767);
            if (Header.Channels = 2) and (I < Length(R)) then
              PCM[I * 2 + 1] := EnsureRange(Round(R[I] * 32768), -32768, 32767)
            else
              PCM[I * 2 + 1] := PCM[I * 2];
          end;
        except
          on E: Exception do
          begin
            FDecoder.Free;
            FDecoder := TMP3Layer3Decoder.Create;
          end;
        end;
      end;
    end;
    FReservoir := FReservoir + Main;
    if Length(FReservoir) > 511 then
      FReservoir := Copy(FReservoir, Length(FReservoir) - 511, 511);
  finally
    Stream.Free;
  end;
end;

{ TPSPMp3Handle }

constructor TPSPMp3Handle.Create;
begin
  inherited Create;
  PassStart := TDictionary<Integer, Int64>.Create;
  Decoder := TPSPMp3FrameDecoder.Create;
end;

destructor TPSPMp3Handle.Destroy;
begin
  Decoder.Free;
  PassStart.Free;
  inherited;
end;

function TPSPMp3Handle.Length_: Int64;
begin
  Result := StreamEnd - StreamStart;
end;

procedure TPSPMp3Handle.ResetStream;
begin
  W := 0;
  R := 0;
  WriteFile := 0;
  ReadFile := 0;
  WritePass := 0;
  ReadPass := 0;
  PassStart.Clear;
  ReaderWaiting := False;
  Sum := 0;
  PcmHalf := 0;
  Decoder.Reset;
end;

{ TPSPMp3 }

constructor TPSPMp3.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FScheduler := System.Scheduler;
  for var I := 0 to High(FHandles) do
    FHandles[I] := TPSPMp3Handle.Create;
end;

destructor TPSPMp3.Destroy;
begin
  for var I := 0 to High(FHandles) do
    FHandles[I].Free;
  inherited;
end;

procedure TPSPMp3.Reset;
begin
  FResource := False;
  for var I := 0 to High(FHandles) do
  begin
    FHandles[I].State := mhFree;
    FHandles[I].ResetStream;
  end;
end;

procedure TPSPMp3.ShortWait(Us: Integer; Result: Cardinal);
begin
  FHLE.Result(Result);
  if not FKernel.CanWait then
    Exit;
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitDelay, nil, 0, 0, False, nil, nil, 'mp3');
  FKernel.AddWakeTimer(FScheduler.Now + Int64(Us) * 1000, T, 'mp3', Result);
end;

// Ready: the error for a handle that was not reserved with stream arguments.
// Inited: the error before sceMp3Init (0 when not required).
function TPSPMp3.Lookup(Index: Integer; out H: TPSPMp3Handle; Ready, Inited: Cardinal): Boolean;
begin
  H := nil;
  Result := False;
  if (Index < 0) or (Index > High(FHandles)) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  H := FHandles[Index];
  if (H.State in [mhFree, mhNoArg]) or not H.HasArg then
  begin
    FHLE.Result(Ready);
    Exit;
  end;
  if (Inited <> 0) and (H.State <> mhInited) then
  begin
    FHLE.Result(Inited);
    Exit;
  end;
  Result := True;
end;

function TPSPMp3.Writable(H: TPSPMp3Handle; out Dst: Cardinal; out SrcPos: Int64): Integer;
begin
  Dst := 0;
  SrcPos := 0;
  if H.WriteFile >= H.Length_ then
  begin
    // The stream is fed again from its start once the decoder has looped.
    if H.WritePass >= H.ReadPass then
      Exit(0);
    H.WritePass := H.ReadPass;
    H.WriteFile := 0;
    H.W := 0;
    H.R := 0;
    H.ReaderWaiting := False;
  end;
  var Limit := (H.R div H.Half) * H.Half + H.RingSize;
  var N := Limit - H.W;
  var Off := Integer(H.W mod H.RingSize);
  if N > H.RingSize - Off then
    N := H.RingSize - Off;
  if N <= 0 then
    Exit(0);
  Dst := GuestAdd(H.RingBase, Off);
  SrcPos := H.StreamStart + H.WriteFile;
  Result := N;
end;

function TPSPMp3.ReadRing(H: TPSPMp3Handle; Pos: Int64; Count: Integer): TBytes;
begin
  SetLength(Result, Count);
  for var I := 0 to Count - 1 do
    Result[I] := FMemory.Read8(GuestAdd(H.RingBase, (Pos + I) mod H.RingSize));
end;

function TPSPMp3.NextPass(H: TPSPMp3Handle): Boolean;
begin
  // The end of the stream: loop back to its start when loops remain.
  if H.LoopNum = 0 then
    Exit(False);
  if H.LoopNum > 0 then
    Dec(H.LoopNum);
  H.Sum := 0;
  Inc(H.ReadPass);
  H.ReadFile := 0;
  H.R := H.W;
  H.ReaderWaiting := True;
  Result := True;
end;

function TPSPMp3.DecodeOne(H: TPSPMp3Handle; out Bytes: Integer): Cardinal;
begin
  Bytes := 0;
  for var Attempt := 0 to 2 do
  begin
    if H.ReaderWaiting then
      Exit(ERROR_MP3_DECODE_NEED_DATA);
    // Data of this pass in the ring.
    var Avail := H.W - H.R;
    var PassLeft := H.Length_ - H.ReadFile;
    if Avail > PassLeft then
      Avail := PassLeft;
    var PassWritten := (H.WritePass > H.ReadPass) or (H.WriteFile >= H.Length_);
    // Find the next header.
    var Skip: Int64 := 0;
    var Found := False;
    var Info: TPSPMp3Header;
    while Skip + 4 <= Avail do
    begin
      var Hdr := ReadRing(H, H.R + Skip, 4);
      if PSPMp3ParseHeader(Hdr, Info) then
      begin
        Found := True;
        Break;
      end;
      Inc(Skip);
    end;
    if not Found then
    begin
      if not PassWritten then
        Exit(ERROR_MP3_DECODE_NEED_DATA);
      if not NextPass(H) then
        Exit(0);
      Continue;
    end;
    if (Skip + Info.FrameSize > Avail) and not PassWritten then
      Exit(ERROR_MP3_DECODE_NEED_DATA);
    var Size := Min(Int64(Info.FrameSize), Avail - Skip);
    var Frame := ReadRing(H, H.R + Skip, Size);
    Inc(H.R, Skip + Size);
    Inc(H.ReadFile, Skip + Size);
    var PCM: TArray<SmallInt>;
    var Channels: Integer;
    var Samples := H.Decoder.Decode(Frame, PCM, Channels);
    if Samples = 0 then
    begin
      Samples := Info.SamplesPerFrame;
      SetLength(PCM, Samples * 2);
    end;
    var Out := GuestAdd(H.Pcm, Int64(H.PcmHalf) * PcmSlot);
    if Length(PCM) > 0 then
      FMemory.WriteBytes(Out, PCM[0], Samples * 4);
    Bytes := Samples * 4;
    Inc(H.Sum, Samples);
    if H.ReadFile >= H.Length_ then
      NextPass(H);
    Exit(0);
  end;
  Result := 0;
end;

{ HLE }

procedure TPSPMp3.hInitResource;
begin
  if FResource then
  begin
    FHLE.Result(0);
    Exit;
  end;
  FResource := True;
  ShortWait(200, 0);
end;

procedure TPSPMp3.hTermResource;
begin
  if not FResource then
  begin
    FHLE.Result(0);
    Exit;
  end;
  FResource := False;
  for var H in FHandles do
  begin
    H.State := mhFree;
    H.ResetStream;
  end;
  ShortWait(200, 0);
end;

procedure TPSPMp3.hReserve;
begin
  var A := FHLE.Arg(0);
  if not FResource then
  begin
    FHLE.Result(ERROR_MP3_NO_RESOURCE_AVAIL);
    Exit;
  end;
  var Index := -1;
  for var I := 0 to High(FHandles) do
    if FHandles[I].State = mhFree then
    begin
      Index := I;
      Break;
    end;
  if Index < 0 then
  begin
    FHLE.Result(ERROR_MP3_NO_RESOURCE_AVAIL);
    Exit;
  end;
  var H := FHandles[Index];
  if A = 0 then
  begin
    H.ResetStream;
    H.State := mhNoArg;
    H.HasArg := False;
    H.Header := Default(TPSPMp3Header);
    FHLE.Result(Cardinal(Index));
    Exit;
  end;
  var Start := Int64(UInt64(FMemory.Read32(A)) or (UInt64(FMemory.Read32(A + 4)) shl 32));
  var Stop := Int64(UInt64(FMemory.Read32(A + 8)) or (UInt64(FMemory.Read32(A + 12)) shl 32));
  var Buf := FMemory.Read32(A + 16);
  var BufSize := Integer(FMemory.Read32(A + 20));
  var Pcm := FMemory.Read32(A + 24);
  var PcmSize := Integer(FMemory.Read32(A + 28));
  if (Start < 0) or (Stop <= Start) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_PARAMETER);
    Exit;
  end;
  if Buf = 0 then
  begin
    FHLE.Result(ERROR_MP3_INVALID_ADDRESS);
    Exit;
  end;
  if BufSize < 8192 then
  begin
    FHLE.Result(ERROR_MP3_INVALID_PARAMETER);
    Exit;
  end;
  if Pcm = 0 then
  begin
    FHLE.Result(ERROR_MP3_INVALID_ADDRESS);
    Exit;
  end;
  if PcmSize < 9216 then
  begin
    FHLE.Result(ERROR_MP3_INVALID_PARAMETER);
    Exit;
  end;
  H.State := mhReserved;
  H.HasArg := True;
  // Only the low word of the end is used for the stream length.
  H.StreamStart := Start;
  H.StreamEnd := Int64(Cardinal(Stop));
  if H.StreamEnd <= H.StreamStart then
    H.StreamEnd := Stop;
  H.Buf := Buf;
  H.BufSize := BufSize;
  H.Pcm := Pcm;
  H.PcmSize := PcmSize;
  H.RingBase := GuestAdd(Buf, RingHead);
  H.Half := (Min(BufSize, $7FFFFFF) - RingHead) div 2;
  H.RingSize := H.Half * 2;
  H.LoopNum := -1;
  H.Header := Default(TPSPMp3Header);
  H.ResetStream;
  FHLE.Result(Cardinal(Index));
end;

procedure TPSPMp3.hRelease;
begin
  var Index := FHLE.ArgInt(0);
  if (Index < 0) or (Index > High(FHandles)) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  FHandles[Index].State := mhFree;
  FHandles[Index].ResetStream;
  FHLE.Result(0);
end;

procedure TPSPMp3.hInit;
begin
  var H: TPSPMp3Handle;
  if not Lookup(FHLE.ArgInt(0), H, ERROR_MP3_UNRESERVED_HANDLE, 0) then
    Exit;
  // Looks for the first sync word near the read position and checks what it says.
  var Base := H.R;
  var Found := -1;
  for var I := 0 to SyncSearch - 1 do
  begin
    var B0 := FMemory.Read8(GuestAdd(H.RingBase, (Base + I) mod H.RingSize));
    var B1 := FMemory.Read8(GuestAdd(H.RingBase, (Base + I + 1) mod H.RingSize));
    if (B0 = $FF) and ((B1 and $E0) = $E0) then
    begin
      Found := I;
      Break;
    end;
  end;
  if Found < 0 then
  begin
    ShortWait(100, ERROR_AVCODEC_INVALID_DATA);
    Exit;
  end;
  var Hdr := ReadRing(H, Base + Found, 4);
  var Version := (Hdr[1] shr 3) and 3;
  var Layer := (Hdr[1] shr 1) and 3;
  var BR := Hdr[2] shr 4;
  var SR := (Hdr[2] shr 2) and 3;
  var Sdk := FKernel.CompiledSdkVersion;
  var E: Cardinal := 0;
  if Layer <> 1 then
    E := ERROR_AVCODEC_INVALID_DATA
  else if (Version <> 3) and ((Version = 1) or (Sdk < $06000000)) then
    E := ERROR_MP3_UNSUPPORTED_VERSION
  else if (BR = 0) or (BR = 15) or (SR = 3) then
    E := ERROR_AVCODEC_INVALID_DATA
  else if (SR <> 0) and (Sdk < $03090500) then
    E := ERROR_MP3_UNSUPPORTED_RATE;
  if E <> 0 then
  begin
    ShortWait(100, E);
    Exit;
  end;
  PSPMp3ParseHeader(Hdr, H.Header);
  H.State := mhInited;
  H.Sum := 0;
  H.PcmHalf := 0;
  H.Decoder.Reset;
  ShortWait(100, 0);
end;

procedure TPSPMp3.hDecode;
begin
  var H: TPSPMp3Handle;
  if not Lookup(FHLE.ArgInt(0), H, ERROR_MP3_UNRESERVED_HANDLE, ERROR_MP3_NOT_YET_INIT_HANDLE) then
    Exit;
  var OutPtr := FHLE.Arg(1);
  var Bytes: Integer;
  var E := DecodeOne(H, Bytes);
  if OutPtr <> 0 then
    FMemory.Write32(OutPtr, GuestAdd(H.Pcm, Int64(H.PcmHalf) * PcmSlot));
  if (E = 0) and (Bytes > 0) then
    H.PcmHalf := H.PcmHalf xor 1;
  if E <> 0 then
    ShortWait(100, E)
  else
    ShortWait(100, Cardinal(Bytes));
end;

procedure TPSPMp3.hNotifyAdd;
begin
  var H: TPSPMp3Handle;
  if not Lookup(FHLE.ArgInt(0), H, ERROR_MP3_UNRESERVED_HANDLE, 0) then
    Exit;
  var N := FHLE.ArgInt(1);
  Inc(H.W, N);
  Inc(H.WriteFile, N);
  FHLE.Result(0);
end;

procedure TPSPMp3.hGetInfoToAdd;
begin
  var H: TPSPMp3Handle;
  if not Lookup(FHLE.ArgInt(0), H, ERROR_MP3_UNRESERVED_HANDLE, 0) then
    Exit;
  var Dst: Cardinal;
  var Src: Int64;
  var N := Writable(H, Dst, Src);
  if N <= 0 then
  begin
    N := 0;
    Dst := 0;
    Src := 0;
  end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Dst);
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(N));
  if FHLE.Arg(3) <> 0 then
    FMemory.Write32(FHLE.Arg(3), Cardinal(Src));
  FHLE.Result(0);
end;

procedure TPSPMp3.hCheckNeeded;
begin
  var H: TPSPMp3Handle;
  if not Lookup(FHLE.ArgInt(0), H, ERROR_MP3_UNRESERVED_HANDLE, 0) then
    Exit;
  var Dst: Cardinal;
  var Src: Int64;
  FHLE.Result(Ord(Writable(H, Dst, Src) > 0));
end;

procedure TPSPMp3.hResetPlayPosition;
begin
  var H: TPSPMp3Handle;
  if not Lookup(FHLE.ArgInt(0), H, ERROR_MP3_UNRESERVED_HANDLE, ERROR_MP3_NOT_YET_INIT_HANDLE) then
    Exit;
  H.ResetStream;
  FHLE.Result(0);
end;

procedure TPSPMp3.hResetPlayPositionByFrame;
begin
  var H: TPSPMp3Handle;
  if not Lookup(FHLE.ArgInt(0), H, ERROR_MP3_UNRESERVED_HANDLE, ERROR_MP3_NOT_YET_INIT_HANDLE) then
    Exit;
  var Frame := FHLE.Arg(1);
  var Info := H.Header;
  var Frames := H.Length_ * Info.SampleRate div (Int64(Info.SamplesPerFrame) * Info.Bitrate * 125);
  if Int64(Frame) >= Frames then
  begin
    FHLE.Result(ERROR_MP3_BAD_RESET_FRAME);
    Exit;
  end;
  // One byte before where the frame should start, so the decoder resyncs on it.
  var Pos: Int64 := 0;
  if Frame > 0 then
    Pos := Int64(Frame) * Info.SamplesPerFrame * Info.Bitrate * 125 div Info.SampleRate - 1;
  H.ResetStream;
  H.WriteFile := Pos;
  H.ReadFile := Pos;
  H.Sum := Int64(Frame) * Info.SamplesPerFrame;
  FHLE.Result(0);
end;

procedure TPSPMp3.hGetSumDecoded;
begin
  if not FResource then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  var H: TPSPMp3Handle;
  if not Lookup(FHLE.ArgInt(0), H, ERROR_MP3_UNRESERVED_HANDLE, 0) then
    Exit;
  FHLE.Result(Cardinal(H.Sum));
end;

procedure TPSPMp3.hSetLoopNum;
begin
  var H: TPSPMp3Handle;
  if not Lookup(FHLE.ArgInt(0), H, ERROR_MP3_UNRESERVED_HANDLE, 0) then
    Exit;
  var N := FHLE.ArgInt(1);
  if N < 0 then
    N := -1;
  H.LoopNum := N;
  FHLE.Result(0);
end;

procedure TPSPMp3.hGetLoopNum;
begin
  var H: TPSPMp3Handle;
  if not Lookup(FHLE.ArgInt(0), H, ERROR_MP3_UNRESERVED_HANDLE, 0) then
    Exit;
  FHLE.Result(Cardinal(H.LoopNum));
end;

// The stream properties: after sceMp3Init, or zero after the low-level init.
procedure TPSPMp3.hGetChannelNum;
begin
  var Index := FHLE.ArgInt(0);
  if (Index < 0) or (Index > High(FHandles)) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  var H := FHandles[Index];
  if not (H.State in [mhInited, mhLowLevel]) then
  begin
    FHLE.Result(ERROR_MP3_NOT_YET_INIT_HANDLE);
    Exit;
  end;
  FHLE.Result(Cardinal(H.Header.Channels));
end;

procedure TPSPMp3.hGetBitRate;
begin
  var Index := FHLE.ArgInt(0);
  if (Index < 0) or (Index > High(FHandles)) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  var H := FHandles[Index];
  if not (H.State in [mhInited, mhLowLevel]) then
  begin
    FHLE.Result(ERROR_MP3_NOT_YET_INIT_HANDLE);
    Exit;
  end;
  FHLE.Result(Cardinal(H.Header.Bitrate));
end;

procedure TPSPMp3.hGetMaxOutputSample;
begin
  var Index := FHLE.ArgInt(0);
  if (Index < 0) or (Index > High(FHandles)) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  var H := FHandles[Index];
  if not (H.State in [mhInited, mhLowLevel]) then
  begin
    FHLE.Result(ERROR_MP3_NOT_YET_INIT_HANDLE);
    Exit;
  end;
  FHLE.Result(Cardinal(H.Header.SamplesPerFrame));
end;

procedure TPSPMp3.hGetSamplingRate;
begin
  var Index := FHLE.ArgInt(0);
  if (Index < 0) or (Index > High(FHandles)) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  var H := FHandles[Index];
  if not (H.State in [mhInited, mhLowLevel]) then
  begin
    FHLE.Result(ERROR_MP3_NOT_YET_INIT_HANDLE);
    Exit;
  end;
  FHLE.Result(Cardinal(H.Header.SampleRate));
end;

procedure TPSPMp3.hGetMPEGVersion;
begin
  var Index := FHLE.ArgInt(0);
  if (Index < 0) or (Index > High(FHandles)) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  var H := FHandles[Index];
  if not (H.State in [mhInited, mhLowLevel]) then
  begin
    FHLE.Result(ERROR_MP3_UNRESERVED_HANDLE);
    Exit;
  end;
  FHLE.Result(Cardinal(H.Header.Version));
end;

procedure TPSPMp3.hGetFrameNum;
begin
  var Index := FHLE.ArgInt(0);
  if (Index < 0) or (Index > High(FHandles)) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  var H := FHandles[Index];
  if H.State <> mhInited then
  begin
    FHLE.Result(ERROR_MP3_NOT_YET_INIT_HANDLE);
    Exit;
  end;
  var Info := H.Header;
  // From the first header's rate, not by counting frames.
  FHLE.Result(Cardinal(H.Length_ * Info.SampleRate div (Int64(Info.SamplesPerFrame) * Info.Bitrate * 125)));
end;

procedure TPSPMp3.hLowLevelInit;
begin
  var Index := FHLE.ArgInt(0);
  if (Index < 0) or (Index > High(FHandles)) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  var H := FHandles[Index];
  if H.State = mhFree then
  begin
    FHLE.Result(ERROR_MP3_UNRESERVED_HANDLE);
    Exit;
  end;
  H.State := mhLowLevel;
  H.Header := Default(TPSPMp3Header);
  H.Decoder.Reset;
  ShortWait(100, 0);
end;

procedure TPSPMp3.hLowLevelDecode;
begin
  var Index := FHLE.ArgInt(0);
  if (Index < 0) or (Index > High(FHandles)) then
  begin
    FHLE.Result(ERROR_MP3_INVALID_HANDLE);
    Exit;
  end;
  var H := FHandles[Index];
  if H.State <> mhLowLevel then
  begin
    FHLE.Result(ERROR_MP3_NOT_YET_INIT_HANDLE);
    Exit;
  end;
  var Src := FHLE.Arg(1);
  var ConsumedPtr := FHLE.Arg(2);
  var Dst := FHLE.Arg(3);
  var WrittenPtr := FHLE.Arg(4);
  var Hdr: array[0..3] of Byte;
  FMemory.ReadBytes(Src, Hdr, 4);
  var Info: TPSPMp3Header;
  var Consumed := 0;
  var Written := 0;
  if PSPMp3ParseHeader(Hdr, Info) then
  begin
    var Frame: TBytes;
    SetLength(Frame, Info.FrameSize);
    FMemory.ReadBytes(Src, Frame[0], Info.FrameSize);
    var PCM: TArray<SmallInt>;
    var Channels: Integer;
    var Samples := H.Decoder.Decode(Frame, PCM, Channels);
    if (Samples > 0) and (Dst <> 0) then
      FMemory.WriteBytes(Dst, PCM[0], Samples * 4);
    Consumed := Info.FrameSize;
    Written := Samples * 4;
  end;
  if ConsumedPtr <> 0 then
    FMemory.Write32(ConsumedPtr, Cardinal(Consumed));
  if WrittenPtr <> 0 then
    FMemory.Write32(WrittenPtr, Cardinal(Written));
  ShortWait(100, 0);
end;

procedure TPSPMp3.hZero;
begin
  FHLE.Result(0);
end;

procedure TPSPMp3.Register;
begin
  var H := FHLE;
  const L = 'sceMp3';
  H.Register(L, $07EC321A, 'sceMp3ReserveMp3Handle', hReserve);
  H.Register(L, $0DB149F4, 'sceMp3NotifyAddStreamData', hNotifyAdd);
  H.Register(L, $2A368661, 'sceMp3ResetPlayPosition', hResetPlayPosition);
  H.Register(L, $354D27EA, 'sceMp3GetSumDecodedSample', hGetSumDecoded);
  H.Register(L, $35750070, 'sceMp3InitResource', hInitResource);
  H.Register(L, $3C2FA058, 'sceMp3TermResource', hTermResource);
  H.Register(L, $3CEF484F, 'sceMp3SetLoopNum', hSetLoopNum);
  H.Register(L, $44E07129, 'sceMp3Init', hInit);
  H.Register(L, $732B042A, 'sceMp3EndEntry', hZero);
  H.Register(L, $7F696782, 'sceMp3GetMp3ChannelNum', hGetChannelNum);
  H.Register(L, $87677E40, 'sceMp3GetBitRate', hGetBitRate);
  H.Register(L, $87C263D1, 'sceMp3GetMaxOutputSample', hGetMaxOutputSample);
  H.Register(L, $8AB81558, 'sceMp3StartEntry', hZero);
  H.Register(L, $8F450998, 'sceMp3GetSamplingRate', hGetSamplingRate);
  H.Register(L, $A703FE0F, 'sceMp3GetInfoToAddStreamData', hGetInfoToAdd);
  H.Register(L, $D021C0FB, 'sceMp3Decode', hDecode);
  H.Register(L, $D0A56296, 'sceMp3CheckStreamDataNeeded', hCheckNeeded);
  H.Register(L, $D8F54A51, 'sceMp3GetLoopNum', hGetLoopNum);
  H.Register(L, $F5478233, 'sceMp3ReleaseMp3Handle', hRelease);
  H.Register(L, $AE6D2027, 'sceMp3GetMPEGVersion', hGetMPEGVersion);
  H.Register(L, $3548AEC8, 'sceMp3GetFrameNum', hGetFrameNum);
  H.Register(L, $0840E808, 'sceMp3ResetPlayPositionByFrame', hResetPlayPositionByFrame);
  H.Register(L, $1B839B83, 'sceMp3LowLevelInit', hLowLevelInit);
  H.Register(L, $E3EE2C81, 'sceMp3LowLevelDecode', hLowLevelDecode);
end;

initialization
  RegisterPSPService(TPSPMp3);

end.
