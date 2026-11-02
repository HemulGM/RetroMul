unit PSP.Atrac;

// sceAtrac3plus: ATRAC3 / ATRAC3+ playback from a buffer the program fills,
// decoded with source/hardware/audio. Each ID has a 256-byte context in
// memory (an sceAudiocodec part and the playback part the program may read);
// it is rewritten after every call and its state byte is read back first.
//
// States: 2 the whole file is in the buffer, 3 the buffer can hold it but is
// being filled, 4 streaming, 5 streaming with a loop that ends at the end,
// 6 streaming with a loop that ends earlier (its tail is in a second buffer),
// 8 low level decoding, 16 used by sceSas.
//
// A streamed file is a sequence of passes: the first runs from the start of
// the file, each later one (looping) from the frames that prime the loop
// start, up to the end of the file or of the loop end frame. Positions in
// that sequence are mapped onto the buffer: the first lap keeps the file's
// own offsets (behind the header), later laps wrap over the buffer from its
// start in whole frames.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel,
  PSP.Scheduler, PSP.Service, PSP.SAS, Audio.ATRAC3, Audio.ATRAC3Plus;

type
  TPSPAtracFrameDecoder = class
  private
    FCodec, FChannels, FOutChannels, FFrameSize: Integer;
    FJoint: Boolean;
    FAt3: TATRAC3Decoder;
    FAt3Plus: TATRAC3PlusDecoder;
  public
    constructor Create(Codec, Channels, OutChannels, FrameSize: Integer; Joint: Boolean);
    destructor Destroy; override;
    procedure Reset;
    // Decodes a frame into interleaved OutChannels samples. Returns 0 or the
    // codec error.
    function Decode(const Frame: TBytes; out PCM: TArray<SmallInt>): Cardinal;
  end;

  TPSPAtracSlot = class
  public
    Index: Integer;
    Codec: Integer;
    InUse: Boolean;
    Ctx: Cardinal;
    State: Integer;
    // Format
    Channels, OutChannels, FrameSize, Spf, Delay: Integer;
    DecChannels: Integer;
    Joint: Boolean;
    SampleRate, Bitrate: Integer;
    DataOff, FileEnd: Int64;
    FirstValid, EndSample: Integer;
    HasLoop: Boolean;
    LoopStart, LoopEnd: Integer;
    LoopNum: Integer;
    LoopPrimePos: Int64;
    LoopPrimeFrames: Integer;
    LEEnd: Int64;
    // Buffers
    Buffer: Cardinal;
    BufSize: Int64;
    SecondBuffer: Cardinal;
    SecondSize: Int64;
    SecondSet: Boolean;
    // Play position
    DecodePos: Integer;
    CurFile: Int64;
    FramesToSkip: Integer;
    W: Int64;
    // Streaming
    SeqStart, Lap1End, RingSize: Int64;
    WV, RV: Int64;
    RPass: Integer;
    CurBuffer: Integer;
    SecondOff: Int64;
    FrozenOff: Int64;
    Err: Cardinal;
    PrimeFailed: Boolean;
    // A frame has been decoded since the data was set.
    Decoded: Boolean;
    Decoder: TPSPAtracFrameDecoder;
    destructor Destroy; override;
    procedure Clear;
    function Streaming: Boolean; inline;
    function Looping: Boolean; inline;
    function PassEnd: Int64; inline;
    function L0: Int64; inline;
    function LL: Int64; inline;
    function PassEndV(P: Integer): Int64;
    function WFile: Int64;
    function Lap(V: Int64): Int64;
    function BufPos(V: Int64): Int64;
    function LapEnd(L: Int64): Int64;
  end;

  TPSPAtrac = class(TPSPService)
  private
    FScheduler: TPSPScheduler;
    FSlots: array of TPSPAtracSlot;
    FCtxBase: Cardinal;
    // The file size an AA3 call passes; 0 while a RIFF header is parsed.
    FAA3FileSize: Int64;
    procedure EnsureContexts;
    procedure Configure(At3Plus, At3: Integer);
    procedure ShortWait(Us: Integer; Result: Cardinal);
    procedure CodecWait(S: TPSPAtracSlot; Step: Integer; Result: Cardinal);
    function Slot(ID: Integer; out S: TPSPAtracSlot): Boolean;
    function Lookup(ID: Integer; out S: TPSPAtracSlot): Boolean;
    function DataError(S: TPSPAtracSlot): Cardinal;
    procedure SyncState(S: TPSPAtracSlot);
    procedure WriteCtx(S: TPSPAtracSlot);
    procedure PrimeFor(S: TPSPAtracSlot; Raw: Integer; out Start, Frames: Integer);
    function Remain(S: TPSPAtracSlot): Integer;
    procedure StreamInfo(S: TPSPAtracSlot; out WritePtr: Cardinal; out Avail: Int64; out FilePos: Int64);
    function FrameAvailable(S: TPSPAtracSlot; Count: Integer = 1): Boolean;
    function ReadFrame(S: TPSPAtracSlot): TBytes;
    procedure AdvanceReader(S: TPSPAtracSlot);
    function DecodeFrame(S: TPSPAtracSlot; out PCM: TArray<SmallInt>): Cardinal;
    function Prime(S: TPSPAtracSlot): Cardinal;
    function NextSamples(S: TPSPAtracSlot): Integer;
    function ParseAA3(S: TPSPAtracSlot; Buf: Cardinal; ReadSize: Int64; out Codec: Integer): Cardinal;
    function ParseHeader(S: TPSPAtracSlot; Buf: Cardinal; ReadSize: Int64; out Codec: Integer): Cardinal;
    function Setup(S: TPSPAtracSlot; Buf: Cardinal; ReadSize, BufSize: Int64; OutChannels: Integer): Cardinal;
    function ResetInfo(S: TPSPAtracSlot; Sample: Integer; var First: array of Cardinal; out Start, Frames: Integer): Cardinal;
    function AllocID(Codec: Integer): Integer;
    procedure SetDataCommon(ID: Integer; Buf, ReadSize, BufSize: Cardinal; OutChannels: Integer);
    procedure SetDataAndGetIDCommon(Buf, ReadSize, BufSize: Cardinal; OutChannels: Integer);
    function SasFactory(Context: Cardinal; out Source: TPSPSasAtracSource): Cardinal;
    procedure hStartEntry;
    procedure hGetAtracID;
    procedure hReleaseAtracID;
    procedure hReinit;
    procedure hSetData;
    procedure hSetHalfwayBuffer;
    procedure hSetDataAndGetID;
    procedure hSetHalfwayBufferAndGetID;
    procedure hSetMOutData;
    procedure hSetMOutHalfwayBuffer;
    procedure hSetMOutDataAndGetID;
    procedure hSetMOutHalfwayBufferAndGetID;
    procedure hSetAA3DataAndGetID;
    procedure hSetAA3HalfwayBufferAndGetID;
    procedure hDecodeData;
    procedure hGetRemainFrame;
    procedure hGetStreamDataInfo;
    procedure hAddStreamData;
    procedure hGetSecondBufferInfo;
    procedure hSetSecondBuffer;
    procedure hIsSecondBufferNeeded;
    procedure hGetNextDecodePosition;
    procedure hGetSoundSample;
    procedure hGetChannel;
    procedure hGetOutputChannel;
    procedure hGetMaxSample;
    procedure hGetNextSample;
    procedure hGetBitrate;
    procedure hGetLoopStatus;
    procedure hSetLoopNum;
    procedure hGetBufferInfoForResetting;
    procedure hResetPlayPosition;
    procedure hGetInternalErrorInfo;
    procedure hLowLevelInitDecoder;
    procedure hLowLevelDecode;
    procedure hGetContextAddress;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

implementation

uses
  System.Math, PSP.AudioCodec;

const
  CODEC_AT3PLUS = $1000;
  CODEC_AT3 = $1001;
  ERROR_ATRAC_API_FAIL = Cardinal($80630002);
  ERROR_ATRAC_NO_ATRACID = Cardinal($80630003);
  ERROR_ATRAC_INVALID_CODECTYPE = Cardinal($80630004);
  ERROR_ATRAC_BAD_ATRACID = Cardinal($80630005);
  ERROR_ATRAC_UNKNOWN_FORMAT = Cardinal($80630006);
  ERROR_ATRAC_WRONG_CODECTYPE = Cardinal($80630007);
  ERROR_ATRAC_BAD_CODEC_PARAMS = Cardinal($80630008);
  ERROR_ATRAC_ALL_DATA_LOADED = Cardinal($80630009);
  ERROR_ATRAC_NO_DATA = Cardinal($80630010);
  ERROR_ATRAC_SIZE_TOO_SMALL = Cardinal($80630011);
  ERROR_ATRAC_SECOND_BUFFER_NEEDED = Cardinal($80630012);
  ERROR_ATRAC_BAD_SAMPLE = Cardinal($80630015);
  ERROR_ATRAC_BAD_FIRST_RESET_SIZE = Cardinal($80630016);
  ERROR_ATRAC_BAD_SECOND_RESET_SIZE = Cardinal($80630017);
  ERROR_ATRAC_ADD_DATA_IS_TOO_BIG = Cardinal($80630018);
  ERROR_ATRAC_NO_LOOP_INFORMATION = Cardinal($80630021);
  ERROR_ATRAC_SECOND_BUFFER_NOT_NEEDED = Cardinal($80630022);
  ERROR_ATRAC_BUFFER_IS_EMPTY = Cardinal($80630023);
  ERROR_ATRAC_ALL_DATA_DECODED = Cardinal($80630024);
  ERROR_ATRAC_IS_LOW_LEVEL = Cardinal($80630031);
  ERROR_ATRAC_IS_FOR_SCESAS = Cardinal($80630040);
  SCE_KERNEL_ERROR_BUSY = Cardinal($80000021);
  SCE_KERNEL_ERROR_OUT_OF_MEMORY = Cardinal($80000022);
  MaxSlots = 6;
  CtxSize = 256;
  Info = $80;

  // What the calls cost (us) as threads/scheduling/callcosts measured them on
  // hardware: the library's own work, then the media engine's decode the
  // caller waits for, while other threads run. Steps: setting the data (it
  // decodes the first frame), the first frame decoded after it, later frames.
  // Index 0 is ATRAC3 (recorded mono), 1 ATRAC3+ (recorded stereo).
  CodecSetData = 0;
  CodecFirstFrame = 1;
  CodecFrame = 2;
  CodecBusyUs: array[0..1, 0..2] of Integer = ((250, 150, 40), (800, 150, 100));
  CodecWaitUs: array[0..1, 0..2] of Integer = ((650, 550, 660), (2700, 2850, 2400));
  RIFF_ = $46464952;
  WAVE_ = $45564157;
  FMT_ = $20746D66;
  FACT_ = $74636166;
  SMPL_ = $6C706D73;
  DATA_ = $61746164;

{ TPSPAtracFrameDecoder }

constructor TPSPAtracFrameDecoder.Create(Codec, Channels, OutChannels, FrameSize: Integer; Joint: Boolean);
begin
  inherited Create;
  FCodec := Codec;
  FChannels := Channels;
  FOutChannels := OutChannels;
  FFrameSize := FrameSize;
  FJoint := Joint;
  Reset;
end;

destructor TPSPAtracFrameDecoder.Destroy;
begin
  FAt3.Free;
  FAt3Plus.Free;
  inherited;
end;

procedure TPSPAtracFrameDecoder.Reset;
begin
  FreeAndNil(FAt3);
  FreeAndNil(FAt3Plus);
  try
    if FCodec = CODEC_AT3PLUS then
      FAt3Plus := TATRAC3PlusDecoder.Create(FChannels, FOutChannels)
    else
      FAt3 := TATRAC3Decoder.Create(FFrameSize, FChannels, FOutChannels, Ord(FJoint));
  except
    FAt3 := nil;
    FAt3Plus := nil;
  end;
end;

function TPSPAtracFrameDecoder.Decode(const Frame: TBytes; out PCM: TArray<SmallInt>): Cardinal;
begin
  PCM := nil;
  if FCodec = CODEC_AT3PLUS then
  begin
    if FAt3Plus = nil then
      Exit($20B);
    try
      PCM := FAt3Plus.Decode(Frame);
      Result := 0;
    except
      Result := $20B;
      Reset;
    end;
    Exit;
  end;
  if FAt3 = nil then
    Exit($186);
  // Each channel's sound unit starts with its id (joint stereo's second one
  // is stored reversed at the end of the frame; the decoder checks it).
  var Bytes := Length(Frame);
  if (Frame[0] and $FC) <> $A0 then
    Exit($182);
  if (FChannels = 2) and not FJoint and ((Frame[Bytes div 2] and $FC) <> $A0) then
    Exit($182);
  try
    PCM := FAt3.Decode(Frame);
    Result := 0;
  except
    if FJoint then
      Result := $183
    else
      Result := $182;
    Reset;
  end;
end;

{ TPSPAtracSlot }

destructor TPSPAtracSlot.Destroy;
begin
  Decoder.Free;
  inherited;
end;

procedure TPSPAtracSlot.Clear;
begin
  State := 1;
  FreeAndNil(Decoder);
  HasLoop := False;
  LoopNum := 0;
  SecondSet := False;
  CurBuffer := 0;
  FramesToSkip := 0;
  PrimeFailed := False;
  Err := 0;
end;

function TPSPAtracSlot.Streaming: Boolean;
begin
  Result := State in [4, 5, 6];
end;

function TPSPAtracSlot.Looping: Boolean;
begin
  Result := State in [5, 6];
end;

function TPSPAtracSlot.PassEnd: Int64;
begin
  if State = 6 then
    Result := LEEnd
  else
    Result := FileEnd;
end;

function TPSPAtracSlot.L0: Int64;
begin
  Result := PassEnd - SeqStart;
end;

function TPSPAtracSlot.LL: Int64;
begin
  Result := PassEnd - LoopPrimePos;
end;

function TPSPAtracSlot.PassEndV(P: Integer): Int64;
begin
  Result := L0 + Int64(P) * LL;
end;

// The file position the writer continues from: at the end of a pass, the
// start of the next one.
function TPSPAtracSlot.WFile: Int64;
begin
  if WV < L0 then
    Exit(SeqStart + WV);
  if not Looping or (LL <= 0) then
    Exit(PassEnd);
  Result := LoopPrimePos + (WV - L0) mod LL;
end;

function TPSPAtracSlot.Lap(V: Int64): Int64;
begin
  if V < Lap1End then
    Result := 0
  else
    Result := 1 + (V - Lap1End) div RingSize;
end;

function TPSPAtracSlot.BufPos(V: Int64): Int64;
begin
  if V < Lap1End then
    Result := V
  else
    Result := (V - Lap1End) mod RingSize;
end;

function TPSPAtracSlot.LapEnd(L: Int64): Int64;
begin
  if L = 0 then
    Result := Lap1End
  else
    Result := RingSize;
end;

{ TPSPAtrac }

constructor TPSPAtrac.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FScheduler := System.Scheduler;
  PSPSasAtracFactory := SasFactory;
end;

destructor TPSPAtrac.Destroy;
begin
  if TMethod(PSPSasAtracFactory).Data = Pointer(Self) then
    PSPSasAtracFactory := nil;
  for var S in FSlots do
    S.Free;
  inherited;
end;

procedure TPSPAtrac.Reset;
begin
  for var S in FSlots do
    S.Free;
  FSlots := nil;
  FCtxBase := 0;
end;

procedure TPSPAtrac.EnsureContexts;
begin
  if FCtxBase <> 0 then
    Exit;
  FCtxBase := FKernel.AllocKernel(MaxSlots * CtxSize, 'SceAtracContexts');
  if FCtxBase <> 0 then
    FMemory.Fill(FCtxBase, 0, MaxSlots * CtxSize);
  if FSlots = nil then
    Configure(2, 2);
end;

procedure TPSPAtrac.Configure(At3Plus, At3: Integer);
begin
  for var S in FSlots do
    S.Free;
  SetLength(FSlots, At3Plus + At3);
  for var I := 0 to High(FSlots) do
  begin
    var S := TPSPAtracSlot.Create;
    S.Index := I;
    if I < At3Plus then
      S.Codec := CODEC_AT3PLUS
    else
      S.Codec := CODEC_AT3;
    if FCtxBase <> 0 then
      S.Ctx := FCtxBase + Cardinal(I) * CtxSize;
    FSlots[I] := S;
  end;
end;

procedure TPSPAtrac.ShortWait(Us: Integer; Result: Cardinal);
begin
  FHLE.Result(Result);
  if not FKernel.CanWait then
    Exit;
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitDelay, nil, 0, 0, False, nil, nil, 'atrac');
  FKernel.AddWakeTimer(FScheduler.Now + Int64(Us) * 1000, T, 'atrac', Result);
end;

procedure TPSPAtrac.CodecWait(S: TPSPAtracSlot; Step: Integer; Result: Cardinal);
begin
  var Plus := Ord(S.Codec = CODEC_AT3PLUS);
  FKernel.Spend(Int64(CodecBusyUs[Plus, Step]) * 1000);
  ShortWait(CodecWaitUs[Plus, Step], Result);
end;

function TPSPAtrac.Slot(ID: Integer; out S: TPSPAtracSlot): Boolean;
begin
  EnsureContexts;
  S := nil;
  if (ID < 0) or (ID > High(FSlots)) or not FSlots[ID].InUse then
  begin
    FHLE.Result(ERROR_ATRAC_BAD_ATRACID);
    Exit(False);
  end;
  S := FSlots[ID];
  SyncState(S);
  Result := True;
end;

function TPSPAtrac.DataError(S: TPSPAtracSlot): Cardinal;
begin
  case S.State of
    2..6:
      Result := 0;
    8:
      Result := ERROR_ATRAC_IS_LOW_LEVEL;
    16:
      Result := ERROR_ATRAC_IS_FOR_SCESAS;
  else
    Result := ERROR_ATRAC_NO_DATA;
  end;
end;

// An ID with data in one of the playback states.
function TPSPAtrac.Lookup(ID: Integer; out S: TPSPAtracSlot): Boolean;
begin
  if not Slot(ID, S) then
    Exit(False);
  var E := DataError(S);
  if E <> 0 then
  begin
    FHLE.Result(E);
    Exit(False);
  end;
  Result := True;
end;

procedure TPSPAtrac.SyncState(S: TPSPAtracSlot);
begin
  if S.Ctx <> 0 then
    S.State := FMemory.Read8(S.Ctx + Info + 21);
end;

procedure TPSPAtrac.WriteCtx(S: TPSPAtracSlot);
begin
  var C := S.Ctx;
  if C = 0 then
    Exit;
  var I := C + Info;
  FMemory.Write32(C + 8, S.Err);
  FMemory.Write32(I + 0, Cardinal(S.DecodePos));
  FMemory.Write32(I + 4, Cardinal(S.EndSample));
  if S.HasLoop then
  begin
    FMemory.Write32(I + 8, Cardinal(S.LoopStart));
    FMemory.Write32(I + 12, Cardinal(S.LoopEnd));
  end
  else
  begin
    FMemory.Write32(I + 8, 0);
    FMemory.Write32(I + 12, 0);
  end;
  FMemory.Write32(I + 16, Cardinal(S.FirstValid));
  FMemory.Write8(I + 20, Cardinal(S.FramesToSkip));
  FMemory.Write8(I + 21, Cardinal(S.State));
  FMemory.Write8(I + 22, Cardinal(S.CurBuffer));
  FMemory.Write8(I + 23, Cardinal(S.Channels));
  FMemory.Write16(I + 24, Cardinal(S.FrameSize));
  FMemory.Write16(I + 26, Cardinal(S.Codec));
  FMemory.Write32(I + 28, Cardinal(S.DataOff));
  FMemory.Write32(I + 32, Cardinal(S.CurFile));
  FMemory.Write32(I + 36, Cardinal(S.FileEnd));
  FMemory.Write32(I + 40, Cardinal(S.LoopNum));
  var Sdb, Off, Off2: Int64;
  Off2 := 0;
  case S.State of
    2:
      begin
        Sdb := S.FileEnd - S.DataOff;
        Off := S.DataOff;
      end;
    3:
      begin
        Sdb := S.W - S.DataOff;
        Off := S.DataOff;
      end;
    4..6:
      case S.CurBuffer of
        0:
          begin
            Sdb := Max(Int64(0), S.WV - S.RV);
            Off := S.BufPos(S.RV);
          end;
        1:
          begin
            Sdb := Max(Int64(0), S.SecondSize - S.SecondOff);
            Off := S.FrozenOff;
            Off2 := S.SecondOff;
          end;
      else
        Sdb := 0;
        Off := 0;
      end;
  else
    Sdb := 0;
    Off := 0;
  end;
  FMemory.Write32(I + 44, Cardinal(Sdb));
  FMemory.Write32(I + 48, Cardinal(Off));
  FMemory.Write32(I + 52, Cardinal(Off2));
  FMemory.Write32(I + 56, S.Buffer);
  FMemory.Write32(I + 60, S.SecondBuffer);
  FMemory.Write32(I + 64, Cardinal(S.BufSize));
  FMemory.Write32(I + 68, Cardinal(S.SecondSize));
  FMemory.Write32(I + 124, Cardinal(S.Index));
end;

// The frames to feed the decoder so that raw sample Raw comes out right: the
// one holding it and the one or two before, as the decoder delay needs.
procedure TPSPAtrac.PrimeFor(S: TPSPAtracSlot; Raw: Integer; out Start, Frames: Integer);
begin
  var F := Raw div S.Spf;
  if Raw mod S.Spf < S.Delay then
  begin
    Start := Max(0, F - 2);
    Frames := 3;
  end
  else
  begin
    Start := F - 1;
    Frames := 2;
  end;
end;

function TPSPAtrac.Remain(S: TPSPAtracSlot): Integer;
begin
  case S.State of
    2:
      Result := -1;
    3:
      Result := Max(Int64(0), (S.W - S.CurFile) div S.FrameSize);
    4:
      if S.WV >= S.L0 then
        Result := -2
      else
        Result := Max(Int64(0), (S.WV - S.RV) div S.FrameSize - S.FramesToSkip);
    5, 6:
      begin
        if S.CurBuffer <> 0 then
          Exit(-2);
        if (S.LoopNum = 0) and (S.WV >= S.PassEndV(S.RPass)) then
          Exit(-3);
        var N := (S.WV - S.RV) div S.FrameSize - S.FramesToSkip;
        // Frames that only prime a loop start do not count.
        var P := S.RPass;
        while (S.LL > 0) and (S.PassEndV(P) < S.WV) do
        begin
          if S.PassEndV(P) > S.RV then
            Dec(N, S.LoopPrimeFrames);
          Inc(P);
        end;
        Result := Max(Int64(0), N);
      end;
  else
    Result := 0;
  end;
end;

procedure TPSPAtrac.StreamInfo(S: TPSPAtracSlot; out WritePtr: Cardinal; out Avail: Int64; out FilePos: Int64);
begin
  WritePtr := S.Buffer;
  Avail := 0;
  FilePos := 0;
  case S.State of
    3:
      begin
        WritePtr := S.Buffer + Cardinal(S.W);
        Avail := S.FileEnd - S.W;
        FilePos := S.W;
      end;
    4..6:
      begin
        if (S.CurBuffer <> 0) or ((S.State = 4) and (S.WV >= S.L0)) then
          Exit;
        var WF := S.WFile;
        var WL := S.Lap(S.WV);
        var WP := S.BufPos(S.WV);
        var Room := S.LapEnd(WL) - WP;
        if WL > S.Lap(S.RV) then
          Room := Min(Room, S.BufPos(S.RV) - WP);
        Avail := Max(Int64(0), Min(Room, S.PassEnd - WF));
        WritePtr := S.Buffer + Cardinal(WP);
        FilePos := WF;
      end;
  end;
end;

function TPSPAtrac.FrameAvailable(S: TPSPAtracSlot; Count: Integer): Boolean;
begin
  var Need := Int64(Count) * S.FrameSize;
  case S.State of
    2:
      Result := S.CurFile + Need <= Min(S.FileEnd, S.BufSize);
    3:
      Result := S.CurFile + Need <= S.W;
    4..6:
      case S.CurBuffer of
        0:
          Result := S.RV + Need <= S.WV;
        1:
          Result := S.SecondSet and (S.SecondOff + Need <= S.SecondSize);
      else
        Result := False;
      end;
  else
    Result := False;
  end;
end;

function TPSPAtrac.ReadFrame(S: TPSPAtracSlot): TBytes;
begin
  SetLength(Result, S.FrameSize);
  case S.State of
    2, 3:
      FMemory.ReadBytes(S.Buffer + Cardinal(S.CurFile), Result[0], S.FrameSize);
    4..6:
      if S.CurBuffer = 1 then
        FMemory.ReadBytes(S.SecondBuffer + Cardinal(S.SecondOff), Result[0], S.FrameSize)
      else
      begin
        var P := S.BufPos(S.RV);
        if P + S.FrameSize <= S.LapEnd(S.Lap(S.RV)) then
          FMemory.ReadBytes(S.Buffer + Cardinal(P), Result[0], S.FrameSize)
        else
          for var I := 0 to S.FrameSize - 1 do
            Result[I] := FMemory.Read8(S.Buffer + Cardinal(S.BufPos(S.RV + I)));
      end;
  end;
end;

procedure TPSPAtrac.AdvanceReader(S: TPSPAtracSlot);
begin
  Inc(S.CurFile, S.FrameSize);
  if S.Streaming then
  begin
    if S.CurBuffer = 1 then
      Inc(S.SecondOff, S.FrameSize)
    else
      Inc(S.RV, S.FrameSize);
  end;
end;

function TPSPAtrac.DecodeFrame(S: TPSPAtracSlot; out PCM: TArray<SmallInt>): Cardinal;
begin
  PCM := nil;
  if S.Decoder = nil then
    S.Decoder := TPSPAtracFrameDecoder.Create(S.Codec, S.DecChannels, S.OutChannels, S.FrameSize, S.Joint);
  // Frames before the data are whatever lies in memory there.
  if S.CurFile < S.DataOff then
    Result := $20B
  else
    Result := S.Decoder.Decode(ReadFrame(S), PCM);
  S.Err := Result;
end;

// Decodes the frames that only warm the decoder up.
function TPSPAtrac.Prime(S: TPSPAtracSlot): Cardinal;
begin
  Result := 0;
  while S.FramesToSkip > 0 do
  begin
    if not FrameAvailable(S) then
      Exit;
    var PCM: TArray<SmallInt>;
    if DecodeFrame(S, PCM) <> 0 then
      Exit(ERROR_ATRAC_API_FAIL);
    Dec(S.FramesToSkip);
    AdvanceReader(S);
  end;
end;

function TPSPAtrac.NextSamples(S: TPSPAtracSlot): Integer;
begin
  if S.DecodePos > S.EndSample then
    Exit(0);
  Result := S.Spf - S.DecodePos mod S.Spf;
  if S.DecodePos + Result - 1 > S.EndSample then
    Result := S.EndSample - S.DecodePos + 1;
end;

// An OMA file: an "ea3" tag, then a 96-byte EA3 header with the codec
// parameters, then the frames. There is no sample count; the file size the
// program passes decides how many frames there are.
function TPSPAtrac.ParseAA3(S: TPSPAtracSlot; Buf: Cardinal; ReadSize: Int64; out Codec: Integer): Cardinal;
const
  Rates: array[0..7] of Integer = (32000, 44100, 48000, 88200, 96000, 0, 0, 0);
begin
  Codec := 0;
  S.HasLoop := False;
  if ReadSize < 10 then
    Exit(ERROR_ATRAC_SIZE_TOO_SMALL);
  if (FMemory.Read8(Buf) <> Ord('e')) or (FMemory.Read8(Buf + 1) <> Ord('a')) or (FMemory.Read8(Buf + 2) <>
    Ord('3')) then
    Exit(ERROR_ATRAC_UNKNOWN_FORMAT);
  var TagSize := Int64(10) + Int64((FMemory.Read8(Buf + 6) and $7F) shl 21) or Int64((FMemory.Read8(Buf + 7) and
      $7F) shl 14) or Int64((FMemory.Read8(Buf + 8) and $7F) shl 7) or Int64(FMemory.Read8(Buf + 9) and $7F);
  if TagSize + 96 > ReadSize then
    Exit(ERROR_ATRAC_SIZE_TOO_SMALL);
  var H := Buf + Cardinal(TagSize);
  if (FMemory.Read8(H) <> Ord('E')) or (FMemory.Read8(H + 1) <> Ord('A')) or (FMemory.Read8(H + 2) <> Ord('3')) then
    Exit(ERROR_ATRAC_UNKNOWN_FORMAT);
  var P := (FMemory.Read8(H + 33) shl 16) or (FMemory.Read8(H + 34) shl 8) or FMemory.Read8(H + 35);
  S.SampleRate := Rates[(P shr 13) and 7];
  case FMemory.Read8(H + 32) of
    0:
      begin
        Codec := CODEC_AT3;
        S.Spf := 1024;
        S.Delay := $45;
        S.Channels := 2;
        S.Joint := ((P shr 17) and 1) <> 0;
        S.FrameSize := Integer(P and $3FF) * 8;
        var Param := PSPAtrac3ParamFor(S.FrameSize, S.Joint, S.Channels);
        var Bytes, Ch: Integer;
        var J: Boolean;
        if not PSPAtrac3Param(Param, Bytes, Ch, J) then
          Exit(ERROR_ATRAC_UNKNOWN_FORMAT);
        S.DecChannels := Ch;
      end;
    1:
      begin
        Codec := CODEC_AT3PLUS;
        S.Spf := 2048;
        S.Delay := $170;
        S.Joint := False;
        S.FrameSize := Integer(P and $3FF) * 8 + 8;
        if ((P shr 10) and 7) = 1 then
          S.Channels := 1
        else
          S.Channels := 2;
        S.DecChannels := S.Channels;
      end;
  else
    Exit(ERROR_ATRAC_UNKNOWN_FORMAT);
  end;
  if (S.FrameSize <= 0) or (S.SampleRate = 0) then
    Exit(ERROR_ATRAC_UNKNOWN_FORMAT);
  if (S.Codec <> 0) and (Codec <> S.Codec) then
    Exit(ERROR_ATRAC_WRONG_CODECTYPE);
  S.DataOff := TagSize + 96;
  var DataSize := (Max(Int64(0), FAA3FileSize - S.DataOff) div S.FrameSize) * S.FrameSize;
  var Total := (DataSize div S.FrameSize) * S.Spf;
  S.FirstValid := S.Spf + S.Delay;
  if Total <= S.FirstValid then
    Exit(ERROR_ATRAC_BAD_CODEC_PARAMS);
  S.EndSample := Integer(Total) - 1;
  S.FileEnd := S.DataOff + DataSize;
  S.Bitrate := Integer(Int64(S.FrameSize) * 8 * S.SampleRate div (Int64(S.Spf) * 1000));
  Result := 0;
end;

function TPSPAtrac.ParseHeader(S: TPSPAtracSlot; Buf: Cardinal; ReadSize: Int64; out Codec: Integer): Cardinal;
begin
  if FAA3FileSize > 0 then
    Exit(ParseAA3(S, Buf, ReadSize, Codec));
  Codec := 0;
  if ReadSize < 12 then
    Exit(ERROR_ATRAC_SIZE_TOO_SMALL);
  if (FMemory.Read32(Buf) <> RIFF_) or (FMemory.Read32(Buf + 8) <> WAVE_) then
    Exit(ERROR_ATRAC_UNKNOWN_FORMAT);
  var Pos: Int64 := 12;
  var HaveFmt := False;
  var HaveData := False;
  var FactEnd: Int64 := -1;
  var FactOffset: Int64 := 0;
  var SmplStart, SmplEnd: Int64;
  S.HasLoop := False;
  SmplStart := 0;
  SmplEnd := 0;
  var DataSize: Int64 := 0;
  while Pos + 8 <= ReadSize do
  begin
    var Id := FMemory.Read32(Buf + Cardinal(Pos));
    var Size := Int64(FMemory.Read32(Buf + Cardinal(Pos) + 4));
    var Body := Buf + Cardinal(Pos) + 8;
    case Id of
      FMT_:
        begin
          var Tag := FMemory.Read16(Body);
          S.Channels := FMemory.Read16(Body + 2);
          S.SampleRate := FMemory.Read32(Body + 4);
          S.FrameSize := FMemory.Read16(Body + 12);
          if Tag = $FFFE then
          begin
            Codec := CODEC_AT3PLUS;
            S.Spf := 2048;
            S.Delay := $170;
            S.DecChannels := S.Channels;
            S.Joint := False;
          end
          else if Tag = $0270 then
          begin
            Codec := CODEC_AT3;
            S.Spf := 1024;
            S.Delay := $45;
            S.Joint := FMemory.Read16(Body + $18) <> 0;
            var Param := PSPAtrac3ParamFor(S.FrameSize, S.Joint, S.Channels);
            var Bytes, Ch: Integer;
            var J: Boolean;
            if not PSPAtrac3Param(Param, Bytes, Ch, J) then
              Exit(ERROR_ATRAC_UNKNOWN_FORMAT);
            S.DecChannels := Ch;
          end
          else
            Exit(ERROR_ATRAC_UNKNOWN_FORMAT);
          if (S.FrameSize <= 0) or not (S.Channels in [1, 2]) then
            Exit(ERROR_ATRAC_UNKNOWN_FORMAT);
          HaveFmt := True;
        end;
      FACT_:
        begin
          FactEnd := FMemory.Read32(Body);
          if Size >= 8 then
            FactOffset := FMemory.Read32(Body + 4);
        end;
      SMPL_:
        if (Size >= 36 + 24) and (FMemory.Read32(Body + 28) > 0) then
        begin
          S.HasLoop := True;
          SmplStart := Integer(FMemory.Read32(Body + 44));
          SmplEnd := Integer(FMemory.Read32(Body + 48));
        end;
      DATA_:
        begin
          S.DataOff := Pos + 8;
          DataSize := Size;
          HaveData := True;
          Break;
        end;
    end;
    Inc(Pos, 8 + Size);
  end;
  if not HaveFmt then
    Exit(ERROR_ATRAC_UNKNOWN_FORMAT);
  if not HaveData then
    Exit(ERROR_ATRAC_SIZE_TOO_SMALL);
  if (S.Codec <> 0) and (Codec <> S.Codec) then
    Exit(ERROR_ATRAC_WRONG_CODECTYPE);
  // An offset of 0 counts as a whole frame.
  var Offset := FactOffset;
  if Offset = 0 then
    Offset := S.Spf;
  var Total := (DataSize div S.FrameSize) * S.Spf;
  if FactEnd < 0 then
    FactEnd := Total - Offset - S.Delay;
  if FactEnd + Offset + S.Delay > Total then
    Exit(ERROR_ATRAC_BAD_CODEC_PARAMS);
  S.FirstValid := Integer(Offset) + S.Delay;
  S.EndSample := Integer(FactEnd) + S.FirstValid - 1;
  S.FileEnd := S.DataOff + DataSize;
  if S.HasLoop then
  begin
    S.LoopStart := Integer(SmplStart) + S.Delay;
    S.LoopEnd := Integer(SmplEnd) + S.Delay;
    if (S.LoopStart > S.LoopEnd) or (S.LoopEnd > S.EndSample) then
      Exit(ERROR_ATRAC_BAD_CODEC_PARAMS);
  end;
  S.Bitrate := Integer(Int64(S.FrameSize) * 8 * S.SampleRate div (Int64(S.Spf) * 1000));
  Result := 0;
end;

function TPSPAtrac.Setup(S: TPSPAtracSlot; Buf: Cardinal; ReadSize, BufSize: Int64; OutChannels: Integer): Cardinal;
begin
  var Codec: Integer;
  if ReadSize > BufSize then
    ReadSize := BufSize;
  S.State := 1;
  FreeAndNil(S.Decoder);
  Result := ParseHeader(S, Buf, ReadSize, Codec);
  if Result <> 0 then
  begin
    S.HasLoop := False;
    Exit;
  end;
  S.OutChannels := OutChannels;
  S.Buffer := Buf;
  S.BufSize := BufSize;
  S.LoopNum := 0;
  S.SecondSet := False;
  S.CurBuffer := 0;
  S.Err := 0;
  S.PrimeFailed := False;
  S.Decoded := False;
  S.RPass := 0;
  if S.HasLoop then
  begin
    var Start, Frames: Integer;
    PrimeFor(S, S.LoopStart, Start, Frames);
    S.LoopPrimePos := S.DataOff + Int64(Start) * S.FrameSize;
    S.LoopPrimeFrames := Frames - 1;
    S.LEEnd := S.DataOff + Int64(S.LoopEnd div S.Spf + 1) * S.FrameSize;
  end;
  if BufSize >= S.FileEnd then
  begin
    if ReadSize >= S.FileEnd then
      S.State := 2
    else
      S.State := 3;
    S.W := Min(ReadSize, S.FileEnd);
  end
  else if not S.HasLoop then
    S.State := 4
  else if S.LoopEnd < S.EndSample then
    S.State := 6
  else
    S.State := 5;
  S.DecodePos := S.FirstValid;
  S.CurFile := S.DataOff;
  S.FramesToSkip := S.FirstValid div S.Spf;
  if S.Streaming then
  begin
    S.SeqStart := 0;
    S.Lap1End := S.DataOff + ((BufSize - S.DataOff) div S.FrameSize) * S.FrameSize;
    S.RingSize := Max(Int64(S.FrameSize), (BufSize div S.FrameSize) * S.FrameSize);
    S.WV := Min(ReadSize, S.L0);
    S.RV := S.DataOff;
  end;
  S.Decoder := TPSPAtracFrameDecoder.Create(S.Codec, S.DecChannels, S.OutChannels, S.FrameSize, S.Joint);
  if Prime(S) <> 0 then
  begin
    S.State := 1;
    S.HasLoop := False;
    Exit(ERROR_ATRAC_API_FAIL);
  end;
  // The end of the buffer past the first lap belongs at the start of the
  // next; it is moved once the frames before have been decoded.
  if S.Streaming and (BufSize > S.Lap1End) then
  begin
    var Extra: TBytes;
    SetLength(Extra, BufSize - S.Lap1End);
    FMemory.ReadBytes(Buf + Cardinal(S.Lap1End), Extra[0], Length(Extra));
    FMemory.WriteBytes(Buf, Extra[0], Length(Extra));
  end;
  Result := 0;
end;

function TPSPAtrac.AllocID(Codec: Integer): Integer;
begin
  EnsureContexts;
  for var S in FSlots do
    if not S.InUse and (S.Codec = Codec) then
    begin
      S.InUse := True;
      S.Clear;
      Exit(S.Index);
    end;
  Result := -1;
end;

{ HLE }

procedure TPSPAtrac.hStartEntry;
begin
  FHLE.Result(0);
end;

procedure TPSPAtrac.hGetAtracID;
begin
  var Codec := FHLE.ArgInt(0);
  if (Codec <> CODEC_AT3PLUS) and (Codec <> CODEC_AT3) then
  begin
    FHLE.Result(ERROR_ATRAC_INVALID_CODECTYPE);
    Exit;
  end;
  var ID := AllocID(Codec);
  if ID < 0 then
  begin
    FHLE.Result(ERROR_ATRAC_NO_ATRACID);
    Exit;
  end;
  WriteCtx(FSlots[ID]);
  FHLE.Result(Cardinal(ID));
end;

procedure TPSPAtrac.hReleaseAtracID;
begin
  var S: TPSPAtracSlot;
  if not Slot(FHLE.ArgInt(0), S) then
    Exit;
  S.InUse := False;
  S.Clear;
  S.State := 0;
  FHLE.Result(0);
end;

procedure TPSPAtrac.hReinit;
begin
  EnsureContexts;
  var At3 := FHLE.ArgInt(0);
  var At3Plus := FHLE.ArgInt(1);
  if FKernel.InInterrupt and ((At3 > 0) or (At3Plus > 0)) then
  begin
    FHLE.Result($807F00FD);
    Exit;
  end;
  for var S in FSlots do
    if S.InUse then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_BUSY);
      Exit;
    end;
  if (At3 < 0) or (At3Plus < 0) then
  begin
    FHLE.Result(0);
    Exit;
  end;
  // Six units of memory: an ATRAC3+ ID takes two, an ATRAC3 one.
  var P := Min(At3Plus, MaxSlots div 2);
  var A := Min(At3, MaxSlots - 2 * P);
  Configure(P, A);
  var R: Cardinal := 0;
  if Int64(At3) + 2 * Int64(At3Plus) > MaxSlots then
    R := SCE_KERNEL_ERROR_OUT_OF_MEMORY;
  if (At3 = 0) and (At3Plus = 0) then
    ShortWait(100, R)
  else
    FHLE.Result(R);
end;

procedure TPSPAtrac.SetDataCommon(ID: Integer; Buf, ReadSize, BufSize: Cardinal; OutChannels: Integer);
begin
  var S: TPSPAtracSlot;
  if not Slot(ID, S) then
    Exit;
  var R := Setup(S, Buf, ReadSize, BufSize, OutChannels);
  WriteCtx(S);
  if (R <> 0) and (R <> ERROR_ATRAC_API_FAIL) then
    FHLE.Result(R)
  else if R = 0 then
    CodecWait(S, CodecSetData, R)
  else
    ShortWait(100, R);
end;

procedure TPSPAtrac.SetDataAndGetIDCommon(Buf, ReadSize, BufSize: Cardinal; OutChannels: Integer);
begin
  EnsureContexts;
  // The header decides the codec, and so which kind of ID.
  var Probe := TPSPAtracSlot.Create;
  try
    var Codec: Integer;
    var R := ParseHeader(Probe, Buf, Min(ReadSize, BufSize), Codec);
    if R <> 0 then
    begin
      FHLE.Result(R);
      Exit;
    end;
    var ID := AllocID(Codec);
    if ID < 0 then
    begin
      FHLE.Result(ERROR_ATRAC_NO_ATRACID);
      Exit;
    end;
    var S := FSlots[ID];
    R := Setup(S, Buf, ReadSize, BufSize, OutChannels);
    if R <> 0 then
    begin
      S.InUse := False;
      S.Clear;
      S.State := 0;
      WriteCtx(S);
      // A first frame that does not decode was still sent to the decoder.
      if R = ERROR_ATRAC_API_FAIL then
        ShortWait(100, R)
      else
        FHLE.Result(R);
      Exit;
    end;
    WriteCtx(S);
    CodecWait(S, CodecSetData, Cardinal(ID));
  finally
    Probe.Free;
  end;
end;

procedure TPSPAtrac.hSetData;
begin
  SetDataCommon(FHLE.ArgInt(0), FHLE.Arg(1), FHLE.Arg(2), FHLE.Arg(2), 2);
end;

procedure TPSPAtrac.hSetHalfwayBuffer;
begin
  SetDataCommon(FHLE.ArgInt(0), FHLE.Arg(1), FHLE.Arg(2), FHLE.Arg(3), 2);
end;

procedure TPSPAtrac.hSetDataAndGetID;
begin
  SetDataAndGetIDCommon(FHLE.Arg(0), FHLE.Arg(1), FHLE.Arg(1), 2);
end;

procedure TPSPAtrac.hSetHalfwayBufferAndGetID;
begin
  SetDataAndGetIDCommon(FHLE.Arg(0), FHLE.Arg(1), FHLE.Arg(2), 2);
end;

procedure TPSPAtrac.hSetMOutData;
begin
  SetDataCommon(FHLE.ArgInt(0), FHLE.Arg(1), FHLE.Arg(2), FHLE.Arg(2), 1);
end;

procedure TPSPAtrac.hSetMOutHalfwayBuffer;
begin
  SetDataCommon(FHLE.ArgInt(0), FHLE.Arg(1), FHLE.Arg(2), FHLE.Arg(3), 1);
end;

procedure TPSPAtrac.hSetMOutDataAndGetID;
begin
  SetDataAndGetIDCommon(FHLE.Arg(0), FHLE.Arg(1), FHLE.Arg(1), 1);
end;

procedure TPSPAtrac.hSetMOutHalfwayBufferAndGetID;
begin
  SetDataAndGetIDCommon(FHLE.Arg(0), FHLE.Arg(1), FHLE.Arg(2), 1);
end;

procedure TPSPAtrac.hSetAA3DataAndGetID;
begin
  FAA3FileSize := FHLE.Arg(2);
  if FAA3FileSize = 0 then
    FAA3FileSize := FHLE.Arg(1);
  try
    SetDataAndGetIDCommon(FHLE.Arg(0), FHLE.Arg(1), FHLE.Arg(1), 2);
  finally
    FAA3FileSize := 0;
  end;
end;

procedure TPSPAtrac.hSetAA3HalfwayBufferAndGetID;
begin
  FAA3FileSize := FHLE.Arg(3);
  if FAA3FileSize = 0 then
    FAA3FileSize := FHLE.Arg(2);
  try
    SetDataAndGetIDCommon(FHLE.Arg(0), FHLE.Arg(1), FHLE.Arg(2), 2);
  finally
    FAA3FileSize := 0;
  end;
end;

procedure TPSPAtrac.hDecodeData;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  var out := FHLE.Arg(1);
  var SamplesPtr := FHLE.Arg(2);
  var FinishPtr := FHLE.Arg(3);
  var RemainPtr := FHLE.Arg(4);
  var Samples := 0;
  var Finish := 0;
  var R: Cardinal;
  if (S.State = 6) and not S.SecondSet and (S.CurBuffer = 1) then
    R := ERROR_ATRAC_SECOND_BUFFER_NEEDED
  else if S.DecodePos > S.EndSample then
  begin
    R := ERROR_ATRAC_ALL_DATA_DECODED;
    Finish := 1;
  end
  else if not FrameAvailable(S, S.FramesToSkip + 1) then
    R := ERROR_ATRAC_BUFFER_IS_EMPTY
  else
  begin
    R := Prime(S);
    var PCM: TArray<SmallInt>;
    if R = 0 then
      if DecodeFrame(S, PCM) <> 0 then
        R := ERROR_ATRAC_API_FAIL;
    if R = 0 then
    begin
      var Skip := S.DecodePos mod S.Spf;
      Samples := NextSamples(S);
      if (out <> 0) and (Length(PCM) > 0) then
        FMemory.WriteBytes(out, PCM[Skip * S.OutChannels], Samples * S.OutChannels * 2);
      var FrameStart := S.DecodePos - Skip;
      AdvanceReader(S);
      Inc(S.DecodePos, Samples);
      if S.HasLoop and (S.LoopNum <> 0) and (S.LoopEnd >= FrameStart) and (S.LoopEnd < FrameStart + S.Spf) then
      begin
        // Back to the loop start, primed from the frames before it.
        S.DecodePos := S.LoopStart;
        if S.LoopNum > 0 then
          Dec(S.LoopNum);
        S.FramesToSkip := S.LoopPrimeFrames;
        S.CurFile := S.LoopPrimePos;
        Inc(S.RPass);
        S.Decoder.Reset;
      end
      else if (S.State = 6) and (S.CurBuffer = 0) and (S.CurFile >= S.LEEnd) then
      begin
        S.FrozenOff := S.BufPos(S.RV);
        S.CurBuffer := 1;
        S.SecondOff := S.CurFile - S.LEEnd;
      end;
      if (S.CurBuffer = 1) and (S.SecondOff >= S.SecondSize) and (S.DecodePos > S.EndSample) then
        S.CurBuffer := 2;
      if S.DecodePos > S.EndSample then
        Finish := 1;
    end;
  end;
  if (R = 0) or (R = ERROR_ATRAC_ALL_DATA_DECODED) or (R = ERROR_ATRAC_BUFFER_IS_EMPTY) or
    (R = ERROR_ATRAC_API_FAIL) then
  begin
    if SamplesPtr <> 0 then
      FMemory.Write32(SamplesPtr, Cardinal(Samples));
    if FinishPtr <> 0 then
      FMemory.Write32(FinishPtr, Cardinal(Finish));
    if RemainPtr <> 0 then
      FMemory.Write32(RemainPtr, Cardinal(Remain(S)));
  end;
  WriteCtx(S);
  if R = 0 then
  begin
    if S.Decoded then
      CodecWait(S, CodecFrame, 0)
    else
      CodecWait(S, CodecFirstFrame, 0);
    S.Decoded := True;
  end
  else
    FHLE.Result(R);
end;

procedure TPSPAtrac.hGetRemainFrame;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(Remain(S)));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hGetStreamDataInfo;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  var P: Cardinal;
  var Avail, FilePos: Int64;
  StreamInfo(S, P, Avail, FilePos);
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), P);
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(Avail));
  if FHLE.Arg(3) <> 0 then
    FMemory.Write32(FHLE.Arg(3), Cardinal(FilePos));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hAddStreamData;
begin
  var S: TPSPAtracSlot;
  if not Slot(FHLE.ArgInt(0), S) then
    Exit;
  var E := DataError(S);
  if E = ERROR_ATRAC_NO_DATA then
    E := ERROR_ATRAC_BAD_ATRACID;
  if E <> 0 then
  begin
    FHLE.Result(E);
    Exit;
  end;
  var Bytes := Int64(FHLE.Arg(1));
  case S.State of
    2:
      begin
        FHLE.Result(ERROR_ATRAC_ALL_DATA_LOADED);
        Exit;
      end;
    3:
      begin
        if S.W + Bytes > S.FileEnd then
        begin
          FHLE.Result(ERROR_ATRAC_ADD_DATA_IS_TOO_BIG);
          Exit;
        end;
        Inc(S.W, Bytes);
        if S.W >= S.FileEnd then
          S.State := 2;
      end;
  else
    begin
      var P: Cardinal;
      var Avail, FilePos: Int64;
      StreamInfo(S, P, Avail, FilePos);
      if Bytes > Avail then
      begin
        FHLE.Result(ERROR_ATRAC_ADD_DATA_IS_TOO_BIG);
        Exit;
      end;
      Inc(S.WV, Bytes);
    end;
  end;
  // Frames the decoder still had to warm up with may have arrived.
  if (S.FramesToSkip > 0) and not S.PrimeFailed and (S.DecodePos = S.FirstValid) and (S.RPass = 0) then
    Prime(S);
  WriteCtx(S);
  FHLE.Result(0);
end;

procedure TPSPAtrac.hGetSecondBufferInfo;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  var PosPtr := FHLE.Arg(1);
  var SizePtr := FHLE.Arg(2);
  if S.State <> 6 then
  begin
    if PosPtr <> 0 then
      FMemory.Write32(PosPtr, 0);
    if SizePtr <> 0 then
      FMemory.Write32(SizePtr, 0);
    FHLE.Result(ERROR_ATRAC_SECOND_BUFFER_NOT_NEEDED);
    Exit;
  end;
  if PosPtr <> 0 then
    FMemory.Write32(PosPtr, Cardinal(S.LEEnd));
  if SizePtr <> 0 then
    FMemory.Write32(SizePtr, Cardinal(S.FileEnd - S.LEEnd));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hSetSecondBuffer;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  var Ptr := FHLE.Arg(1);
  var Size := Int64(FHLE.Arg(2));
  var MinSize := Int64(3) * S.FrameSize;
  if S.State = 6 then
    MinSize := Min(MinSize, S.FileEnd - S.LEEnd);
  if Size < MinSize then
  begin
    FHLE.Result(ERROR_ATRAC_SIZE_TOO_SMALL);
    Exit;
  end;
  if S.State <> 6 then
  begin
    FHLE.Result(ERROR_ATRAC_SECOND_BUFFER_NOT_NEEDED);
    Exit;
  end;
  S.SecondBuffer := Ptr;
  S.SecondSize := Size;
  S.SecondSet := True;
  WriteCtx(S);
  FHLE.Result(0);
end;

procedure TPSPAtrac.hIsSecondBufferNeeded;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  FHLE.Result(Ord(S.State = 6));
end;

procedure TPSPAtrac.hGetNextDecodePosition;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if S.DecodePos > S.EndSample then
  begin
    FHLE.Result(ERROR_ATRAC_ALL_DATA_DECODED);
    Exit;
  end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(S.DecodePos - S.FirstValid));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hGetSoundSample;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(S.EndSample - S.FirstValid));
  var LS := -1;
  var LE := -1;
  if S.HasLoop then
  begin
    LS := S.LoopStart - S.FirstValid;
    LE := S.LoopEnd - S.FirstValid;
  end;
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(LS));
  if FHLE.Arg(3) <> 0 then
    FMemory.Write32(FHLE.Arg(3), Cardinal(LE));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hGetChannel;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(S.Channels));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hGetOutputChannel;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(S.OutChannels));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hGetMaxSample;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(S.Spf));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hGetNextSample;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(NextSamples(S)));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hGetBitrate;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(S.Bitrate));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hGetLoopStatus;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(S.LoopNum));
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Ord(S.HasLoop and (S.DecodePos <= S.LoopEnd)));
  FHLE.Result(0);
end;

procedure TPSPAtrac.hSetLoopNum;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if not S.HasLoop then
  begin
    FHLE.Result(ERROR_ATRAC_NO_LOOP_INFORMATION);
    Exit;
  end;
  S.LoopNum := FHLE.ArgInt(1);
  WriteCtx(S);
  FHLE.Result(0);
end;

// First: write pointer, writable bytes, minimum bytes, file position.
function TPSPAtrac.ResetInfo(S: TPSPAtracSlot; Sample: Integer; var First: array of Cardinal; out Start, Frames: Integer): Cardinal;
begin
  Start := 0;
  Frames := 0;
  if (S.State = 6) and not S.SecondSet then
    Exit(ERROR_ATRAC_SECOND_BUFFER_NEEDED);
  var R := Int64(Sample) + S.FirstValid;
  if (Sample > S.EndSample - S.FirstValid) or (R < 0) then
    Exit(ERROR_ATRAC_BAD_SAMPLE);
  PrimeFor(S, Integer(R), Start, Frames);
  var FS := Int64(S.FrameSize);
  var FilePos := S.DataOff + Start * FS;
  First[0] := S.Buffer;
  First[1] := 0;
  First[2] := 0;
  First[3] := 0;
  case S.State of
    3:
      begin
        First[0] := S.Buffer + Cardinal(S.W);
        First[1] := Cardinal(S.FileEnd - S.W);
        First[2] := Cardinal(Max(Int64(0), FilePos + Frames * FS - S.W));
        First[3] := Cardinal(S.W);
      end;
    4, 5:
      begin
        First[1] := Cardinal(Min(S.RingSize, S.FileEnd - FilePos));
        First[2] := Cardinal(Frames * FS);
        First[3] := Cardinal(FilePos);
      end;
    6:
      begin
        var LE := S.LoopEnd div S.Spf;
        if Start <= LE then
        begin
          First[1] := Cardinal(Min(S.RingSize, S.LEEnd - FilePos));
          First[2] := Cardinal(Min(Frames, LE - Start + 1) * FS);
          First[3] := Cardinal(FilePos);
        end
        else
        begin
          var U := LE + 1 + S.SecondSize div FS;
          if Start >= U then
          begin
            First[1] := Cardinal(Min(S.RingSize, S.FileEnd - FilePos));
            First[2] := Cardinal(Frames * FS);
            First[3] := Cardinal(FilePos);
          end
          else
          begin
            var P := S.DataOff + U * FS;
            if P < S.FileEnd then
            begin
              First[1] := Cardinal(Min(S.RingSize, S.FileEnd - P));
              First[2] := Cardinal(Max(Int64(0), Start + Frames - U) * FS);
              First[3] := Cardinal(P);
            end;
          end;
        end;
      end;
  end;
  if S.PrimeFailed then
    Exit(ERROR_ATRAC_API_FAIL);
  Result := 0;
end;

procedure TPSPAtrac.hGetBufferInfoForResetting;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  var Sample := FHLE.ArgInt(1);
  var Ptr := FHLE.Arg(2);
  var First: array[0..3] of Cardinal;
  var Start, Frames: Integer;
  var R := ResetInfo(S, Sample, First, Start, Frames);
  if (R = 0) or (R = ERROR_ATRAC_API_FAIL) then
    if Ptr <> 0 then
    begin
      for var I := 0 to 3 do
        FMemory.Write32(Ptr + Cardinal(I) * 4, First[I]);
      FMemory.Write32(Ptr + 16, S.Buffer);
      for var I := 1 to 3 do
        FMemory.Write32(Ptr + 16 + Cardinal(I) * 4, 0);
    end;
  FHLE.Result(R);
end;

procedure TPSPAtrac.hResetPlayPosition;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  var Sample := FHLE.ArgInt(1);
  var Bytes1 := Int64(FHLE.Arg(2));
  var Bytes2 := Int64(FHLE.Arg(3));
  var First: array[0..3] of Cardinal;
  var Start, Frames: Integer;
  var R := ResetInfo(S, Sample, First, Start, Frames);
  if (R <> 0) and (R <> ERROR_ATRAC_API_FAIL) then
  begin
    FHLE.Result(R);
    Exit;
  end;
  case S.State of
    2:
      begin
        if Bytes1 <> 0 then
          R := ERROR_ATRAC_BAD_FIRST_RESET_SIZE
        else if Bytes2 <> 0 then
          R := ERROR_ATRAC_BAD_SECOND_RESET_SIZE
        else
          R := 0;
      end;
    3:
      begin
        if (Bytes1 > First[1]) or (Bytes1 < First[2]) then
          R := ERROR_ATRAC_BAD_FIRST_RESET_SIZE
        else if Bytes2 <> 0 then
          R := ERROR_ATRAC_BAD_SECOND_RESET_SIZE
        else
          R := 0;
      end;
  else
    if (Bytes1 > First[1]) or (Bytes1 < First[2]) then
      R := ERROR_ATRAC_BAD_FIRST_RESET_SIZE
    else if (S.State = 6) and (Bytes2 > S.SecondSize) then
      R := ERROR_ATRAC_BAD_SECOND_RESET_SIZE
    else
      R := 0;
  end;
  if R <> 0 then
  begin
    FHLE.Result(R);
    Exit;
  end;
  var FS := Int64(S.FrameSize);
  S.DecodePos := Sample + S.FirstValid;
  S.FramesToSkip := Frames - 1;
  S.PrimeFailed := False;
  S.Err := 0;
  S.CurBuffer := 0;
  S.RPass := 0;
  S.CurFile := S.DataOff + Start * FS;
  if S.Decoder <> nil then
    S.Decoder.Reset;
  case S.State of
    3:
      begin
        Inc(S.W, Bytes1);
        if S.W >= S.FileEnd then
          S.State := 2;
      end;
    4..6:
      if (S.State = 6) and (Start > S.LoopEnd div S.Spf) then
      begin
        // Past the loop: the frames are in the second buffer.
        S.CurBuffer := 1;
        S.SecondOff := S.CurFile - S.LEEnd;
        S.FrozenOff := 0;
        S.SeqStart := S.LEEnd;
        S.Lap1End := 0;
        S.WV := 0;
        S.RV := 0;
      end
      else
      begin
        S.SeqStart := S.CurFile;
        S.Lap1End := 0;
        S.WV := Bytes1;
        S.RV := 0;
      end;
  end;
  if Prime(S) <> 0 then
  begin
    S.PrimeFailed := True;
    WriteCtx(S);
    ShortWait(100, ERROR_ATRAC_API_FAIL);
    Exit;
  end;
  WriteCtx(S);
  ShortWait(100, 0);
end;

procedure TPSPAtrac.hGetInternalErrorInfo;
begin
  var S: TPSPAtracSlot;
  if not Lookup(FHLE.ArgInt(0), S) then
    Exit;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), S.Err);
  FHLE.Result(0);
end;

procedure TPSPAtrac.hLowLevelInitDecoder;
begin
  var S: TPSPAtracSlot;
  if not Slot(FHLE.ArgInt(0), S) then
    Exit;
  var P := FHLE.Arg(1);
  S.Channels := FMemory.Read32(P);
  S.OutChannels := FMemory.Read32(P + 4);
  S.FrameSize := FMemory.Read32(P + 8);
  if not (S.Channels in [1, 2]) then
    S.Channels := 2;
  if not (S.OutChannels in [1, 2]) then
    S.OutChannels := 2;
  S.DecChannels := S.Channels;
  S.Joint := False;
  if S.Codec = CODEC_AT3PLUS then
    S.Spf := 2048
  else
  begin
    S.Spf := 1024;
    // ATRAC3 frames of a size only joint stereo uses.
    var Param := PSPAtrac3ParamFor(S.FrameSize, False, S.Channels);
    if Param < 0 then
    begin
      Param := PSPAtrac3ParamFor(S.FrameSize, True, S.Channels);
      S.Joint := Param >= 0;
    end;
    var Bytes, Ch: Integer;
    var J: Boolean;
    if PSPAtrac3Param(Param, Bytes, Ch, J) then
      S.DecChannels := Ch;
  end;
  FreeAndNil(S.Decoder);
  S.Decoder := TPSPAtracFrameDecoder.Create(S.Codec, S.DecChannels, S.OutChannels, S.FrameSize, S.Joint);
  S.State := 8;
  WriteCtx(S);
  FHLE.Result(0);
end;

procedure TPSPAtrac.hLowLevelDecode;
begin
  var S: TPSPAtracSlot;
  if not Slot(FHLE.ArgInt(0), S) then
    Exit;
  if (S.State <> 8) or (S.Decoder = nil) then
  begin
    FHLE.Result(ERROR_ATRAC_NO_DATA);
    Exit;
  end;
  var Src := FHLE.Arg(1);
  var ConsumedPtr := FHLE.Arg(2);
  var Dst := FHLE.Arg(3);
  var WrittenPtr := FHLE.Arg(4);
  var Frame: TBytes;
  SetLength(Frame, S.FrameSize);
  FMemory.ReadBytes(Src, Frame[0], S.FrameSize);
  var PCM: TArray<SmallInt>;
  var E := S.Decoder.Decode(Frame, PCM);
  S.Err := E;
  var Written := 0;
  if (E = 0) and (Dst <> 0) and (Length(PCM) > 0) then
  begin
    Written := Length(PCM) * 2;
    FMemory.WriteBytes(Dst, PCM[0], Written);
  end;
  if ConsumedPtr <> 0 then
    FMemory.Write32(ConsumedPtr, Cardinal(S.FrameSize));
  if WrittenPtr <> 0 then
    FMemory.Write32(WrittenPtr, Cardinal(Written));
  WriteCtx(S);
  ShortWait(100, 0);
end;

procedure TPSPAtrac.hGetContextAddress;
begin
  EnsureContexts;
  var ID := FHLE.ArgInt(0);
  if (ID < 0) or (ID > High(FSlots)) or not FSlots[ID].InUse then
  begin
    FHLE.Result(0);
    Exit;
  end;
  FHLE.Result(FSlots[ID].Ctx);
end;

{ sceSas ATRAC3 voices }

type
  TPSPAtracSasSource = class(TPSPSasAtracSource)
  private
    FOwner: TPSPAtrac;
    FSlot: TPSPAtracSlot;
    FData: TBytes;
    FPos: Integer;
    FPCM: TArray<SmallInt>;
    FPCMPos: Integer;
    FSkip: Integer;
    FDecoder: TPSPAtracFrameDecoder;
    procedure Load;
  public
    constructor Create(Owner: TPSPAtrac; Slot: TPSPAtracSlot);
    destructor Destroy; override;
    function Read(Buffer: PSmallInt; Count: Integer): Boolean; override;
    procedure Restart; override;
    procedure Concatenate(Address: Cardinal; Size: Integer); override;
  end;

constructor TPSPAtracSasSource.Create(Owner: TPSPAtrac; Slot: TPSPAtracSlot);
begin
  inherited Create;
  FOwner := Owner;
  FSlot := Slot;
  FDecoder := TPSPAtracFrameDecoder.Create(Slot.Codec, Slot.DecChannels, 1, Slot.FrameSize, Slot.Joint);
  Load;
end;

destructor TPSPAtracSasSource.Destroy;
begin
  FDecoder.Free;
  inherited;
end;

procedure TPSPAtracSasSource.Load;
begin
  var S := FSlot;
  var Last := S.FileEnd;
  if S.State = 3 then
    Last := S.W;
  Last := Min(Last, S.BufSize);
  FData := nil;
  if Last > S.DataOff then
  begin
    SetLength(FData, Last - S.DataOff);
    FOwner.FMemory.ReadBytes(S.Buffer + Cardinal(S.DataOff), FData[0], Length(FData));
  end;
  FPos := 0;
  FPCM := nil;
  FPCMPos := 0;
  FSkip := S.FirstValid;
  FDecoder.Reset;
end;

procedure TPSPAtracSasSource.Restart;
begin
  // sceSas puts back the buffer pointer a program may have moved.
  if FSlot.Ctx <> 0 then
    FOwner.FMemory.Write32(FSlot.Ctx + Info + 56, FSlot.Buffer);
  FPos := 0;
  FPCM := nil;
  FPCMPos := 0;
  FSkip := FSlot.FirstValid;
  FDecoder.Reset;
end;

procedure TPSPAtracSasSource.Concatenate(Address: Cardinal; Size: Integer);
begin
  if Size <= 0 then
    Exit;
  var Old := Length(FData);
  SetLength(FData, Old + Size);
  FOwner.FMemory.ReadBytes(Address, FData[Old], Size);
end;

function TPSPAtracSasSource.Read(Buffer: PSmallInt; Count: Integer): Boolean;
begin
  if FSlot.Ctx <> 0 then
    FOwner.FMemory.Write32(FSlot.Ctx + Info + 56, FSlot.Buffer);
  Result := True;
  while Count > 0 do
  begin
    if FPCMPos >= Length(FPCM) then
    begin
      var FS := FSlot.FrameSize;
      if FPos + FS > Length(FData) then
      begin
        while Count > 0 do
        begin
          Buffer^ := 0;
          Inc(Buffer);
          Dec(Count);
        end;
        Exit(False);
      end;
      var Frame := Copy(FData, FPos, FS);
      Inc(FPos, FS);
      if FDecoder.Decode(Frame, FPCM) <> 0 then
        SetLength(FPCM, FSlot.Spf);
      FPCMPos := 0;
      if FSkip > 0 then
      begin
        var N := Min(FSkip, Length(FPCM));
        Inc(FPCMPos, N);
        Dec(FSkip, N);
        Continue;
      end;
    end;
    Buffer^ := FPCM[FPCMPos];
    Inc(Buffer);
    Inc(FPCMPos);
    Dec(Count);
  end;
end;

function TPSPAtrac.SasFactory(Context: Cardinal; out Source: TPSPSasAtracSource): Cardinal;
begin
  Source := nil;
  EnsureContexts;
  for var S in FSlots do
    if S.InUse and (S.Ctx = Context) then
    begin
      SyncState(S);
      if S.FrameSize <= 0 then
        Exit(ERROR_ATRAC_NO_DATA);
      Source := TPSPAtracSasSource.Create(Self, S);
      Exit(0);
    end;
  Result := 0;
end;

procedure TPSPAtrac.Register;
begin
  var H := FHLE;
  const L = 'sceAtrac3plus';
  H.Register(L, $D1F59FDB, 'sceAtracStartEntry', hStartEntry);
  H.Register(L, $D5C28CC0, 'sceAtracEndEntry', hStartEntry);
  H.Register(L, $780F88D1, 'sceAtracGetAtracID', hGetAtracID);
  H.Register(L, $61EB33F5, 'sceAtracReleaseAtracID', hReleaseAtracID);
  H.Register(L, $132F1ECA, 'sceAtracReinit', hReinit);
  H.Register(L, $0E2A73AB, 'sceAtracSetData', hSetData);
  H.Register(L, $3F6E26B5, 'sceAtracSetHalfwayBuffer', hSetHalfwayBuffer);
  H.Register(L, $7A20E7AF, 'sceAtracSetDataAndGetID', hSetDataAndGetID);
  H.Register(L, $0FAE370E, 'sceAtracSetHalfwayBufferAndGetID', hSetHalfwayBufferAndGetID);
  H.Register(L, $F6837A1A, 'sceAtracSetMOutData', hSetMOutData);
  H.Register(L, $5CF9D852, 'sceAtracSetMOutHalfwayBuffer', hSetMOutHalfwayBuffer);
  H.Register(L, $472E3825, 'sceAtracSetMOutDataAndGetID', hSetMOutDataAndGetID);
  H.Register(L, $9CD7DE03, 'sceAtracSetMOutHalfwayBufferAndGetID', hSetMOutHalfwayBufferAndGetID);
  H.Register(L, $5622B7C1, 'sceAtracSetAA3DataAndGetID', hSetAA3DataAndGetID);
  H.Register(L, $5DD66588, 'sceAtracSetAA3HalfwayBufferAndGetID', hSetAA3HalfwayBufferAndGetID);
  H.Register(L, $6A8C3CD5, 'sceAtracDecodeData', hDecodeData);
  H.Register(L, $9AE849A7, 'sceAtracGetRemainFrame', hGetRemainFrame);
  H.Register(L, $5D268707, 'sceAtracGetStreamDataInfo', hGetStreamDataInfo);
  H.Register(L, $7DB31251, 'sceAtracAddStreamData', hAddStreamData);
  H.Register(L, $83E85EA0, 'sceAtracGetSecondBufferInfo', hGetSecondBufferInfo);
  H.Register(L, $83BF7AFD, 'sceAtracSetSecondBuffer', hSetSecondBuffer);
  H.Register(L, $ECA32A99, 'sceAtracIsSecondBufferNeeded', hIsSecondBufferNeeded);
  H.Register(L, $E23E3A35, 'sceAtracGetNextDecodePosition', hGetNextDecodePosition);
  H.Register(L, $A2BBA8BE, 'sceAtracGetSoundSample', hGetSoundSample);
  H.Register(L, $31668BAA, 'sceAtracGetChannel', hGetChannel);
  H.Register(L, $B3B5D042, 'sceAtracGetOutputChannel', hGetOutputChannel);
  H.Register(L, $D6A5F2F7, 'sceAtracGetMaxSample', hGetMaxSample);
  H.Register(L, $36FAABFB, 'sceAtracGetNextSample', hGetNextSample);
  H.Register(L, $A554A158, 'sceAtracGetBitrate', hGetBitrate);
  H.Register(L, $FAA4F89B, 'sceAtracGetLoopStatus', hGetLoopStatus);
  H.Register(L, $868120B5, 'sceAtracSetLoopNum', hSetLoopNum);
  H.Register(L, $CA3CA3D2, 'sceAtracGetBufferInfoForReseting', hGetBufferInfoForResetting);
  H.Register(L, $2DD3E298, 'sceAtracGetBufferInfoForResetting', hGetBufferInfoForResetting);
  H.Register(L, $644E5607, 'sceAtracResetPlayPosition', hResetPlayPosition);
  H.Register(L, $E88F759B, 'sceAtracGetInternalErrorInfo', hGetInternalErrorInfo);
  H.Register(L, $1575D64B, 'sceAtracLowLevelInitDecoder', hLowLevelInitDecoder);
  H.Register(L, $0C116E1B, 'sceAtracLowLevelDecode', hLowLevelDecode);
  H.Register(L, $231FC6B7, '_sceAtracGetContextAddress', hGetContextAddress);
end;

initialization
  RegisterPSPService(TPSPAtrac);

end.

