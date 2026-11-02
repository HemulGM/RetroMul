unit PSP.Audio;

// sceAudio, sceVaudio and sceAudioRouting on the master clock.
// The eight PCM channels are mixed by the driver in blocks of 64 samples: a
// buffer handed to an idle mixer starts the DMA and its first block is mixed at
// once, after that one block every 64 samples of guest time; the DMA stops at a
// block with nothing to mix. A channel has one playing buffer and room for one
// parked blocking caller. Output2, SRC and Vaudio share one more channel with two
// DMA descriptors that retire after their whole length at their own rate.
// Everything is mixed into a ring indexed by 44.1 kHz guest sample time, which
// TakeSamples drains.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel,
  PSP.Scheduler, PSP.Service;

const
  PSPAudioChannelCount = 8;
  PSPAudioBlock = 64;

  SCE_AUDIO_ERROR_NOT_INITIALIZED = Cardinal($80260001);
  SCE_AUDIO_ERROR_OUTPUT_BUSY = Cardinal($80260002);
  SCE_AUDIO_ERROR_INVALID_CHANNEL = Cardinal($80260003);
  SCE_AUDIO_ERROR_NO_CHANNELS = Cardinal($80260005);
  SCE_AUDIO_ERROR_INVALID_SIZE = Cardinal($80260006);
  SCE_AUDIO_ERROR_INVALID_FORMAT = Cardinal($80260007);
  SCE_AUDIO_ERROR_NOT_RESERVED = Cardinal($80260008);
  SCE_AUDIO_ERROR_INVALID_FREQUENCY = Cardinal($8026000A);
  SCE_AUDIO_ERROR_INVALID_VOLUME = Cardinal($8026000B);
  SCE_AUDIO_ERROR_SRC_BUSY = Cardinal($80268002);

type
  TPSPAudioChannel = record
    Reserved: Boolean;
    SampleCount: Integer;
    Format: Cardinal;
    VolLeft, VolRight: Integer;
    // Samples not mixed yet. A null output sets it without arming a buffer.
    Rest: Integer;
    Playing: Boolean;
    Buffer: Cardinal;
    PlayCount: Integer;
    PlayFormat: Cardinal;
    // A thread parked in a blocking output and the buffer it hands over.
    Waiter: TPSPThread;
    WaitBuffer: Cardinal;
    WaitLeft, WaitRight: Integer;
  end;
  PPSPAudioChannel = ^TPSPAudioChannel;

  TPSPAudioDescriptor = record
    Buffer: Cardinal;
    Count: Integer;
    Volume: Integer;
    StartAt, EndAt: Int64;
  end;

  TPSPAudio = class(TPSPService)
  private
    FScheduler: TPSPScheduler;
    FCh: array[0..PSPAudioChannelCount - 1] of TPSPAudioChannel;
    FRing: TArray<Integer>;
    FTaken: Int64;
    // Main mixer DMA.
    FMixRunning: Boolean;
    FMixStart: Int64;
    FMixStartPos: Int64;
    FMixTick: Int64;
    FBlock: array[0..PSPAudioBlock * 2 - 1] of Integer;
    // Output2 / SRC / Vaudio channel.
    FO2Reserved: Boolean;
    FO2Count: Integer;
    FO2Freq: Integer;
    FO2Desc: array[0..1] of TPSPAudioDescriptor;
    FO2Armed: Integer;
    FO2Running: Boolean;
    FO2StopAt: Int64;
    FO2Waiter: TPSPThread;
    FO2WaitNull: Boolean;
    FO2WaitRelease: Boolean;
    FO2WaitFailed: Boolean;
    FVaudioBusy: Boolean;
    // Microphone input (none attached: captures silence).
    FInputInit: Boolean;
    FInputBusy: Boolean;
    FInputEnd: Int64;
    FInputStart: Int64;
    FInputCount: Integer;
    FInputFreq: Integer;
    FInputWaiter: TPSPThread;
    FRoutingMode, FRoutingVolumeMode: Cardinal;
    function SamplePos(At: Int64): Int64; inline;
    procedure AddRing(Pos: Int64; L, R: Integer); inline;
    procedure Cost(Us: Integer);
    function TickTime(Tick: Int64): Int64; inline;
    procedure StartMixer;
    procedure MixTick;
    procedure MixChannel(var C: TPSPAudioChannel);
    procedure Arm(Index: Integer; Buffer: Cardinal);
    procedure InstallWaiter(Index: Integer);
    procedure RenderDescriptor(const D: TPSPAudioDescriptor);
    // SetupUs: for an idle DMA, how far into the call playback starts.
    procedure ArmDescriptor(Buffer: Cardinal; Volume: Integer; SetupUs: Integer = 0);
    procedure RetireDescriptor;
    procedure StopOutput2;
    procedure WakeOutput2(Result: Cardinal);
    procedure ReleaseOutput2;
    procedure Process;
    procedure ScheduleNext;
    procedure ParkCurrent(const Tag: string);
    procedure ShortWait(Us: Integer; Result: Cardinal);
    procedure AbortChannelWait(T: TPSPThread);
    procedure AbortOutput2Wait(T: TPSPThread);
    procedure AbortInputWait(T: TPSPThread);
    procedure ChannelOutput(Ch: Integer; Left, Right: Integer; Buffer: Cardinal; Blocking: Boolean);
    procedure Output2Output(Volume: Integer; Buffer: Cardinal);
    function InputCheck(Samples, Freq: Integer; out Error: Cardinal): Boolean;
    procedure StartInput(Samples, Freq: Integer; Buffer: Cardinal);
    procedure FinishInput;
    // HLE
    procedure hChReserve;
    procedure hChRelease;
    procedure hOutput;
    procedure hOutputBlocking;
    procedure hOutputPanned;
    procedure hOutputPannedBlocking;
    procedure hOneshotOutput;
    procedure hGetChannelRestLen;
    procedure hGetChannelRestLength;
    procedure hSetChannelDataLen;
    procedure hChangeChannelConfig;
    procedure hChangeChannelVolume;
    procedure hOutput2Reserve;
    procedure hOutput2OutputBlocking;
    procedure hOutput2Release;
    procedure hOutput2ChangeLength;
    procedure hOutput2GetRestSample;
    procedure hSRCChReserve;
    procedure hSRCOutputBlocking;
    procedure hSetFrequency;
    procedure hZero;
    procedure hInputInit;
    procedure hInput;
    procedure hInputBlocking;
    procedure hGetInputLength;
    procedure hWaitInputEnd;
    procedure hPollInputEnd;
    procedure hVaudioChReserve;
    procedure hVaudioChRelease;
    procedure hVaudioOutputBlocking;
    procedure hRoutingGetMode;
    procedure hRoutingSetMode;
    procedure hRoutingGetVolumeMode;
    procedure hRoutingSetVolumeMode;
  public
    constructor Create(System: TPSPSystem); override;
    procedure Reset; override;
    procedure Register; override;
    procedure OnEvent(Event: TPSPEvent); override;
    // Stereo samples produced since the last call, up to the current guest time.
    function TakeSamples: TArray<SmallInt>;
  end;

implementation

uses
  System.Math;

const
  RingFrames = 1 shl 17;
  RingMask = RingFrames - 1;
  // The descriptor DMA keeps running briefly after its last descriptor retires.
  Output2StopNs = 500000;

  SCE_ERROR_NOT_INIT_INPUT = Cardinal($80000001);
  SCE_ERROR_NOT_SUPPORTED_3 = Cardinal($80000003);
  SCE_ERROR_BUSY = Cardinal($80000021);
  SCE_KERNEL_ERROR_INVALID_VALUE_ROUTING = Cardinal($802C01FE);

function ValidChannelSamples(N: Integer): Boolean; inline;
begin
  Result := (N >= 64) and (N <= 65472) and ((N and 63) = 0);
end;

function ValidOutput2Samples(N: Cardinal): Boolean; inline;
begin
  N := N and $7FFFFFFF;
  Result := (N >= 17) and (N <= 4111);
end;

function ValidFormat(F: Cardinal): Boolean; inline;
begin
  Result := (F = 0) or (F = $10);
end;

function ValidSRCFrequency(F: Integer): Boolean;
begin
  case F of
    0, 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000:
      Result := True;
  else
    Result := False;
  end;
end;

function Scale(S, Vol: Integer): Integer; inline;
begin
  Result := EnsureRange((Int64(S) * Vol) div 32768, -$1000000, $1000000);
end;

{ TPSPAudio }

constructor TPSPAudio.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FScheduler := System.Scheduler;
  SetLength(FRing, RingFrames * 2);
end;

procedure TPSPAudio.Reset;
begin
  FillChar(FCh, SizeOf(FCh), 0);
  for var I := 0 to High(FCh) do
  begin
    FCh[I].VolLeft := $8000;
    FCh[I].VolRight := $8000;
  end;
  FillChar(FRing[0], Length(FRing) * SizeOf(Integer), 0);
  FTaken := SamplePos(FScheduler.Now);
  FMixRunning := False;
  FMixTick := 0;
  FO2Reserved := False;
  FO2Count := 0;
  FO2Freq := 44100;
  FO2Armed := 0;
  FO2Running := False;
  FO2Waiter := nil;
  FO2WaitNull := False;
  FO2WaitRelease := False;
  FO2WaitFailed := False;
  FVaudioBusy := False;
  FInputInit := False;
  FInputBusy := False;
  FInputWaiter := nil;
  FRoutingMode := 0;
  FRoutingVolumeMode := 0;
  FScheduler.Cancel(TPSPEvent.Audio);
end;

function TPSPAudio.SamplePos(At: Int64): Int64;
begin
  Result := At * PSPAudioRate div 1000000000;
end;

procedure TPSPAudio.AddRing(Pos: Int64; L, R: Integer);
begin
  if (Pos < FTaken) or (Pos >= FTaken + RingFrames) then
    Exit;
  var I := Integer(Pos and RingMask) * 2;
  Inc(FRing[I], L);
  Inc(FRing[I + 1], R);
end;

procedure TPSPAudio.Cost(Us: Integer);
begin
  FHLE.CPU.AddCycles(Us * Integer(FScheduler.MHz));
end;

function TPSPAudio.TakeSamples: TArray<SmallInt>;
begin
  var Total := SamplePos(FScheduler.Now);
  var N := Total - FTaken;
  if N < 0 then
    N := 0;
  SetLength(Result, N * 2);
  for var K := 0 to N - 1 do
  begin
    var I := Integer((FTaken + K) and RingMask) * 2;
    Result[K * 2] := EnsureRange(FRing[I], -32768, 32767);
    Result[K * 2 + 1] := EnsureRange(FRing[I + 1], -32768, 32767);
    FRing[I] := 0;
    FRing[I + 1] := 0;
  end;
  FTaken := Total;
end;

{ Main mixer }

function TPSPAudio.TickTime(Tick: Int64): Int64;
begin
  Result := FMixStart + Tick * PSPAudioBlock * 1000000000 div PSPAudioRate;
end;

procedure TPSPAudio.StartMixer;
begin
  FMixRunning := True;
  FMixStart := FScheduler.Now;
  FMixStartPos := SamplePos(FMixStart);
  FMixTick := 0;
  MixTick;
  ScheduleNext;
end;

procedure TPSPAudio.MixChannel(var C: TPSPAudioChannel);
begin
  var N := Min(PSPAudioBlock, C.Rest);
  var Offset := C.PlayCount - C.Rest;
  if C.Buffer <> 0 then
  begin
    if C.PlayFormat = $10 then
    begin
      var P := PSmallInt(FMemory.Ptr(C.Buffer + Cardinal(Offset) * 2, N * 2));
      if P <> nil then
        for var I := 0 to N - 1 do
        begin
          var S := Integer(P^);
          Inc(FBlock[I * 2], Scale(S, C.VolLeft));
          Inc(FBlock[I * 2 + 1], Scale(S, C.VolRight));
          Inc(P);
        end;
    end
    else
    begin
      var P := PSmallInt(FMemory.Ptr(C.Buffer + Cardinal(Offset) * 4, N * 4));
      if P <> nil then
        for var I := 0 to N - 1 do
        begin
          Inc(FBlock[I * 2], Scale(P^, C.VolLeft));
          Inc(P);
          Inc(FBlock[I * 2 + 1], Scale(P^, C.VolRight));
          Inc(P);
        end;
    end;
  end;
  Dec(C.Rest, N);
end;

procedure TPSPAudio.MixTick;
begin
  var Any := False;
  FillChar(FBlock, SizeOf(FBlock), 0);
  for var Ch := 0 to High(FCh) do
    if FCh[Ch].Playing then
    begin
      Any := True;
      MixChannel(FCh[Ch]);
      if FCh[Ch].Rest <= 0 then
      begin
        FCh[Ch].Rest := 0;
        FCh[Ch].Playing := False;
        FCh[Ch].Buffer := 0;
        if FCh[Ch].Waiter <> nil then
          InstallWaiter(Ch);
      end;
    end;
  if not Any then
  begin
    FMixRunning := False;
    Exit;
  end;
  var Pos := FMixStartPos + FMixTick * PSPAudioBlock;
  for var I := 0 to PSPAudioBlock - 1 do
    AddRing(Pos + I, FBlock[I * 2], FBlock[I * 2 + 1]);
  Inc(FMixTick);
end;

procedure TPSPAudio.Arm(Index: Integer; Buffer: Cardinal);
begin
  var C: PPSPAudioChannel := @FCh[Index];
  C.Rest := C.SampleCount;
  if Buffer = 0 then
  begin
    // A null buffer only sets the count; nothing plays.
    C.Playing := False;
    C.Buffer := 0;
    Exit;
  end;
  C.Buffer := Buffer;
  C.PlayCount := C.SampleCount;
  C.PlayFormat := C.Format;
  C.Playing := True;
  if not FMixRunning then
    StartMixer;
end;

procedure TPSPAudio.InstallWaiter(Index: Integer);
begin
  var C: PPSPAudioChannel := @FCh[Index];
  var T := C.Waiter;
  C.Waiter := nil;
  if C.WaitLeft >= 0 then
    C.VolLeft := C.WaitLeft;
  if C.WaitRight >= 0 then
    C.VolRight := C.WaitRight;
  C.Rest := C.SampleCount;
  if C.WaitBuffer <> 0 then
  begin
    C.Buffer := C.WaitBuffer;
    C.PlayCount := C.SampleCount;
    C.PlayFormat := C.Format;
    C.Playing := True;
  end;
  if T.IsWaiting and (T.Wait.HLETag = 'audio') then
    FKernel.EndWait(T, Cardinal(C.SampleCount));
end;

{ Output2 / SRC }

procedure TPSPAudio.RenderDescriptor(const D: TPSPAudioDescriptor);
begin
  if D.Buffer = 0 then
    Exit;
  var Freq := FO2Freq;
  var Pos := SamplePos(D.StartAt);
  var OutCount := Int64(D.Count) * PSPAudioRate div Freq;
  var P := PSmallInt(FMemory.Ptr(D.Buffer, D.Count * 4));
  if P = nil then
    Exit;
  for var I := 0 to OutCount - 1 do
  begin
    var Src := Integer(I * Freq div PSPAudioRate);
    if Src >= D.Count then
      Break;
    var S := PSmallInt(PByte(P) + Src * 4);
    var L := Integer(S^);
    Inc(S);
    var R := Integer(S^);
    AddRing(Pos + I, Scale(L, D.Volume), Scale(R, D.Volume));
  end;
end;

procedure TPSPAudio.ArmDescriptor(Buffer: Cardinal; Volume: Integer; SetupUs: Integer);
begin
  var D := Default(TPSPAudioDescriptor);
  D.Buffer := Buffer;
  D.Count := FO2Count;
  D.Volume := Volume;
  if FO2Armed > 0 then
    D.StartAt := FO2Desc[FO2Armed - 1].EndAt
  else
    D.StartAt := FScheduler.Now + Int64(SetupUs) * 1000;
  D.EndAt := D.StartAt + Int64(D.Count) * 1000000000 div FO2Freq;
  FO2Desc[FO2Armed] := D;
  Inc(FO2Armed);
  FO2Running := True;
  RenderDescriptor(D);
  ScheduleNext;
end;

procedure TPSPAudio.WakeOutput2(Result: Cardinal);
begin
  var T := FO2Waiter;
  FO2Waiter := nil;
  var Release := FO2WaitRelease;
  FO2WaitNull := False;
  FO2WaitRelease := False;
  if Release then
  begin
    ReleaseOutput2;
    FVaudioBusy := False;
  end;
  if T.IsWaiting and (T.Wait.HLETag = 'audio2') then
    FKernel.EndWait(T, Result);
end;

procedure TPSPAudio.RetireDescriptor;
begin
  FO2WaitFailed := False;
  var Done := FO2Desc[0];
  FO2Desc[0] := FO2Desc[1];
  Dec(FO2Armed);
  if FO2Armed = 0 then
    FO2StopAt := Done.EndAt + Output2StopNs;
  if FO2Waiter <> nil then
  begin
    if not FO2WaitNull then
      WakeOutput2(Cardinal(FO2Desc[0].Count))
    else if FO2Armed = 0 then
      WakeOutput2(0);
  end;
end;

procedure TPSPAudio.StopOutput2;
begin
  FO2Running := False;
  FO2WaitFailed := False;
  if (FO2Waiter <> nil) and FO2WaitNull then
    WakeOutput2(0);
end;

procedure TPSPAudio.ReleaseOutput2;
begin
  FO2Reserved := False;
end;

{ Events }

procedure TPSPAudio.Process;
begin
  var Did: Boolean;
  repeat
    var Now := FScheduler.Now;
    Did := False;
    if FMixRunning and (TickTime(FMixTick) <= Now) then
    begin
      MixTick;
      Did := True;
    end;
    if (FO2Armed > 0) and (FO2Desc[0].EndAt <= Now) then
    begin
      RetireDescriptor;
      Did := True;
    end
    else if FO2Running and (FO2Armed = 0) and (FO2StopAt <= Now) then
    begin
      StopOutput2;
      Did := True;
    end;
    if FInputBusy and (FInputEnd <= Now) then
    begin
      FinishInput;
      Did := True;
    end;
  until not Did;
  ScheduleNext;
end;

procedure TPSPAudio.ScheduleNext;
begin
  var At := PSPNever;
  if FMixRunning then
    At := TickTime(FMixTick);
  if FO2Armed > 0 then
    At := Min(At, FO2Desc[0].EndAt)
  else if FO2Running then
    At := Min(At, FO2StopAt);
  if FInputBusy then
    At := Min(At, FInputEnd);
  if At = PSPNever then
    FScheduler.Cancel(TPSPEvent.Audio)
  else
    FScheduler.Schedule(TPSPEvent.Audio, At);
end;

procedure TPSPAudio.OnEvent(Event: TPSPEvent);
begin
  if Event = TPSPEvent.Audio then
    Process;
end;

{ Waits }

procedure TPSPAudio.AbortChannelWait(T: TPSPThread);
begin
  for var I := 0 to High(FCh) do
    if FCh[I].Waiter = T then
      FCh[I].Waiter := nil;
end;

procedure TPSPAudio.AbortOutput2Wait(T: TPSPThread);
begin
  if FO2Waiter = T then
  begin
    FO2Waiter := nil;
    FO2WaitNull := False;
    FO2WaitRelease := False;
  end;
end;

procedure TPSPAudio.AbortInputWait(T: TPSPThread);
begin
  if FInputWaiter = T then
    FInputWaiter := nil;
end;

procedure TPSPAudio.ParkCurrent(const Tag: string);
begin
  if Tag = 'audio' then
    FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, AbortChannelWait, Tag)
  else if Tag = 'audio2' then
    FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, AbortOutput2Wait, Tag)
  else
    FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, AbortInputWait, Tag);
end;

procedure TPSPAudio.ShortWait(Us: Integer; Result: Cardinal);
begin
  FHLE.Result(Result);
  if not FKernel.CanWait then
    Exit;
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitDelay, nil, 0, 0, False, nil, nil, 'audiodelay');
  FKernel.AddWakeTimer(FScheduler.Now + Int64(Us) * 1000, T, 'audiodelay', Result);
end;

{ Channels }

procedure TPSPAudio.ChannelOutput(Ch: Integer; Left, Right: Integer; Buffer: Cardinal; Blocking: Boolean);
begin
  var C: PPSPAudioChannel := @FCh[Ch];
  if C.Waiter <> nil then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_OUTPUT_BUSY);
    Exit;
  end;
  if C.Playing then
  begin
    if not Blocking then
    begin
      FHLE.Result(SCE_AUDIO_ERROR_OUTPUT_BUSY);
      Exit;
    end;
    if not FKernel.CanWait then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
      Exit;
    end;
    Cost(5);
    C.Waiter := FKernel.Current;
    C.WaitBuffer := Buffer;
    C.WaitLeft := Left;
    C.WaitRight := Right;
    FHLE.Result(Cardinal(C.SampleCount));
    ParkCurrent('audio');
    Exit;
  end;
  if Left >= 0 then
    C.VolLeft := Left;
  if Right >= 0 then
    C.VolRight := Right;
  var Starts := (Buffer <> 0) and not FMixRunning;
  Arm(Ch, Buffer);
  if Starts then
    Cost(150)
  else
    Cost(10);
  FHLE.Result(Cardinal(C.SampleCount));
end;

procedure TPSPAudio.hChReserve;
begin
  var Ch := FHLE.ArgInt(0);
  var Samples := FHLE.ArgInt(1);
  var Format := FHLE.Arg(2);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  if Ch < 0 then
  begin
    // The automatic search skips channels still playing out a buffer.
    for var I := High(FCh) downto 0 do
      if not FCh[I].Reserved and not FCh[I].Playing then
      begin
        Ch := I;
        Break;
      end;
    if Ch < 0 then
    begin
      FHLE.Result(SCE_AUDIO_ERROR_NO_CHANNELS);
      Exit;
    end;
  end
  else if FCh[Ch].Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  if not ValidChannelSamples(Samples) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_SIZE);
    Exit;
  end;
  if not ValidFormat(Format) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_FORMAT);
    Exit;
  end;
  var C: PPSPAudioChannel := @FCh[Ch];
  C.Reserved := True;
  C.SampleCount := Samples;
  C.Format := Format;
  FHLE.Result(Cardinal(Ch));
end;

procedure TPSPAudio.hChRelease;
begin
  var Ch := FHLE.Arg(0);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  var C: PPSPAudioChannel := @FCh[Ch];
  if not C.Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_RESERVED);
    Exit;
  end;
  if C.Waiter <> nil then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_OUTPUT_BUSY);
    Exit;
  end;
  // A buffer still playing plays out.
  C.Reserved := False;
  FHLE.Result(0);
end;

procedure TPSPAudio.hOutput;
begin
  var Ch := FHLE.Arg(0);
  var Vol := FHLE.ArgInt(1);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  if not FCh[Ch].Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if Vol > $FFFF then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_VOLUME);
    Exit;
  end;
  ChannelOutput(Ch, Vol, Vol, FHLE.Arg(2), False);
end;

procedure TPSPAudio.hOutputBlocking;
begin
  var Ch := FHLE.Arg(0);
  var Vol := FHLE.ArgInt(1);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  if not FCh[Ch].Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if Vol > $FFFF then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_VOLUME);
    Exit;
  end;
  ChannelOutput(Ch, Vol, Vol, FHLE.Arg(2), True);
end;

procedure TPSPAudio.hOutputPanned;
begin
  var Ch := FHLE.Arg(0);
  var L := FHLE.ArgInt(1);
  var R := FHLE.ArgInt(2);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  if not FCh[Ch].Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if (L > $FFFF) or (R > $FFFF) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_VOLUME);
    Exit;
  end;
  ChannelOutput(Ch, L, R, FHLE.Arg(3), False);
end;

procedure TPSPAudio.hOutputPannedBlocking;
begin
  var Ch := FHLE.Arg(0);
  var L := FHLE.Arg(1);
  var R := FHLE.Arg(2);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  if not FCh[Ch].Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  // Unlike the other outputs this one compares unsigned: negative is too loud.
  if (L > $FFFF) or (R > $FFFF) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_VOLUME);
    Exit;
  end;
  ChannelOutput(Ch, Integer(L), Integer(R), FHLE.Arg(3), True);
end;

procedure TPSPAudio.hOneshotOutput;
begin
  var Ch := FHLE.ArgInt(0);
  var Samples := FHLE.ArgInt(1);
  var Format := FHLE.Arg(2);
  var L := FHLE.Arg(3);
  var R := FHLE.Arg(4);
  var Buffer := FHLE.Arg(5);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  if Ch < 0 then
  begin
    for var I := High(FCh) downto 0 do
      if not FCh[I].Reserved and not FCh[I].Playing then
      begin
        Ch := I;
        Break;
      end;
    if Ch < 0 then
    begin
      FHLE.Result(SCE_AUDIO_ERROR_NO_CHANNELS);
      Exit;
    end;
  end
  else if FCh[Ch].Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  if Samples <= 0 then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_SIZE);
    Exit;
  end;
  if not ValidFormat(Format) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_FORMAT);
    Exit;
  end;
  if (L > $FFFF) or (R > $FFFF) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_VOLUME);
    Exit;
  end;
  var C: PPSPAudioChannel := @FCh[Ch];
  C.VolLeft := L;
  C.VolRight := R;
  C.Rest := Samples;
  if Buffer <> 0 then
  begin
    C.Buffer := Buffer;
    C.PlayCount := Samples;
    C.PlayFormat := Format;
    C.Playing := True;
    if not FMixRunning then
      StartMixer;
  end;
  FHLE.Result(Cardinal(Ch));
end;

procedure TPSPAudio.hGetChannelRestLen;
begin
  var Ch := FHLE.Arg(0);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  var C: PPSPAudioChannel := @FCh[Ch];
  var N := C.Rest;
  if C.Waiter <> nil then
    Inc(N, C.SampleCount);
  FHLE.Result(Cardinal(N));
end;

procedure TPSPAudio.hGetChannelRestLength;
begin
  var Ch := FHLE.Arg(0);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  var C: PPSPAudioChannel := @FCh[Ch];
  var N := 0;
  if C.Playing then
  begin
    N := C.Rest;
    if C.Waiter <> nil then
      Inc(N, C.SampleCount);
  end;
  FHLE.Result(Cardinal(N));
end;

procedure TPSPAudio.hSetChannelDataLen;
begin
  var Ch := FHLE.Arg(0);
  var Len := FHLE.ArgInt(1);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  if not ValidChannelSamples(Len) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_SIZE);
    Exit;
  end;
  var C: PPSPAudioChannel := @FCh[Ch];
  if not C.Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if C.Waiter <> nil then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_OUTPUT_BUSY);
    Exit;
  end;
  C.SampleCount := Len;
  FHLE.Result(0);
end;

procedure TPSPAudio.hChangeChannelConfig;
begin
  var Ch := FHLE.Arg(0);
  var Format := FHLE.Arg(1);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  var C: PPSPAudioChannel := @FCh[Ch];
  if not C.Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_RESERVED);
    Exit;
  end;
  if not ValidFormat(Format) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_FORMAT);
    Exit;
  end;
  if C.Waiter <> nil then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_OUTPUT_BUSY);
    Exit;
  end;
  C.Format := Format;
  FHLE.Result(0);
end;

procedure TPSPAudio.hChangeChannelVolume;
begin
  var Ch := FHLE.Arg(0);
  var L := FHLE.ArgInt(1);
  var R := FHLE.ArgInt(2);
  if Ch >= PSPAudioChannelCount then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_CHANNEL);
    Exit;
  end;
  if (L > $FFFF) or (R > $FFFF) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_VOLUME);
    Exit;
  end;
  var C: PPSPAudioChannel := @FCh[Ch];
  if C.Reserved then
  begin
    if L >= 0 then
      C.VolLeft := L;
    if R >= 0 then
      C.VolRight := R;
  end;
  FHLE.Result(0);
end;

{ Output2 / SRC }

procedure TPSPAudio.Output2Output(Volume: Integer; Buffer: Cardinal);
begin
  if (FO2Waiter <> nil) or FO2WaitFailed then
  begin
    Cost(50);
    FHLE.Result(SCE_AUDIO_ERROR_OUTPUT_BUSY);
    Exit;
  end;
  if Buffer = 0 then
  begin
    // A null buffer waits for the DMA to run dry.
    FHLE.Result(0);
    if (FO2Armed = 0) and not FO2Running then
      Exit;
    if not FKernel.CanWait then
      Exit;
    FO2Waiter := FKernel.Current;
    FO2WaitNull := True;
    FO2WaitRelease := False;
    ParkCurrent('audio2');
    Exit;
  end;
  var Count := FO2Count;
  if FO2Armed = 0 then
  begin
    // The setup takes most of the call; the DMA starts at its end.
    Cost(120);
    ArmDescriptor(Buffer, Volume, 120);
    FHLE.Result(Cardinal(Count));
    Exit;
  end;
  if not FKernel.CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  // Arms the second descriptor, then waits for the first to retire.
  Cost(20);
  ArmDescriptor(Buffer, Volume);
  FO2Waiter := FKernel.Current;
  FO2WaitNull := False;
  FO2WaitRelease := False;
  FHLE.Result(Cardinal(Count));
  ParkCurrent('audio2');
end;

procedure TPSPAudio.hOutput2Reserve;
begin
  var Samples := FHLE.Arg(0);
  if not ValidOutput2Samples(Samples) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
    Exit;
  end;
  if FO2Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_SRC_BUSY);
    Exit;
  end;
  FO2Reserved := True;
  FO2Count := Samples and $7FFFFFFF;
  FO2Freq := PSPAudioRate;
  FHLE.Result(0);
end;

procedure TPSPAudio.hOutput2OutputBlocking;
begin
  var Vol := FHLE.Arg(0);
  if not FO2Reserved then
  begin
    Cost(120);
    FHLE.Result(SCE_AUDIO_ERROR_NOT_RESERVED);
    Exit;
  end;
  if Vol > $FFFFF then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_VOLUME);
    Exit;
  end;
  Output2Output(Vol, FHLE.Arg(1));
end;

procedure TPSPAudio.hOutput2Release;
begin
  if not FO2Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_RESERVED);
    Exit;
  end;
  if (FO2Armed > 0) or (FO2Waiter <> nil) or FO2WaitFailed then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_SRC_BUSY);
    Exit;
  end;
  ReleaseOutput2;
  FHLE.Result(0);
end;

procedure TPSPAudio.hOutput2ChangeLength;
begin
  var Len := FHLE.ArgInt(0);
  if (Len < 17) or (Len > 4111) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_SIZE);
    Exit;
  end;
  if not FO2Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_RESERVED);
    Exit;
  end;
  FO2Count := Len;
  FHLE.Result(0);
end;

procedure TPSPAudio.hOutput2GetRestSample;
begin
  if not FO2Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_RESERVED);
    Exit;
  end;
  // Counts armed descriptors in the current length.
  FHLE.Result(Cardinal(FO2Armed * FO2Count));
end;

procedure TPSPAudio.hSRCChReserve;
begin
  var Samples := FHLE.Arg(0);
  var Freq := FHLE.ArgInt(1);
  var Channels := FHLE.ArgInt(2);
  if not ValidOutput2Samples(Samples) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
    Exit;
  end;
  if Channels = 4 then
  begin
    FHLE.Result(SCE_ERROR_NOT_SUPPORTED_3);
    Exit;
  end;
  if Channels <> 2 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
    Exit;
  end;
  if not ValidSRCFrequency(Freq) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_FREQUENCY);
    Exit;
  end;
  if FO2Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_SRC_BUSY);
    Exit;
  end;
  FO2Reserved := True;
  FO2Count := Samples and $7FFFFFFF;
  if Freq = 0 then
    Freq := PSPAudioRate;
  FO2Freq := Freq;
  FHLE.Result(0);
end;

procedure TPSPAudio.hSRCOutputBlocking;
begin
  var Vol := FHLE.Arg(0);
  if not FO2Reserved then
  begin
    Cost(120);
    FHLE.Result(SCE_AUDIO_ERROR_NOT_RESERVED);
    Exit;
  end;
  if Vol > $FFFFF then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_VOLUME);
    Exit;
  end;
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if (FO2Armed >= Length(FO2Desc)) or (FO2Waiter <> nil) then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_OUTPUT_BUSY);
    Exit;
  end;
  var Buffer := FHLE.Arg(1);
  if (Buffer <> 0) and not FKernel.CanWait then
  begin
    // SRC submits the descriptor before its kernel wait. A refused wait does
    // not undo DMA ownership: two such submissions fill the descriptor queue.
    // Keep the failed-wait lock separately, not as a pointer to a running thread.
    ArmDescriptor(Buffer, Vol);
    FO2WaitFailed := True;
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  Output2Output(Vol, Buffer);
end;

procedure TPSPAudio.hSetFrequency;
begin
  var F := FHLE.Arg(0);
  if (F = 44100) or (F = 48000) then
    FHLE.Result(0)
  else
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_FREQUENCY);
end;

procedure TPSPAudio.hZero;
begin
  FHLE.Result(0);
end;

{ Vaudio }

procedure TPSPAudio.hVaudioChReserve;
begin
  var Samples := FHLE.ArgInt(0);
  var Freq := FHLE.ArgInt(1);
  var Channels := FHLE.ArgInt(2);
  if (Samples < 256) or (Samples > 2048) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
    Exit;
  end;
  if (Channels <> 2) and (Channels <> 4) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_FORMAT);
    Exit;
  end;
  if FVaudioBusy then
  begin
    FHLE.Result(SCE_ERROR_BUSY);
    Exit;
  end;
  // The library marks itself in use before it reserves the shared channel, and a
  // failure there leaves it marked until sceVaudioChRelease.
  FVaudioBusy := True;
  var R: Cardinal := 0;
  if not ValidSRCFrequency(Freq) then
    R := SCE_AUDIO_ERROR_INVALID_FREQUENCY
  else if FO2Reserved then
    R := SCE_AUDIO_ERROR_SRC_BUSY
  else
  begin
    FO2Reserved := True;
    FO2Count := Samples;
    if Freq = 0 then
      Freq := PSPAudioRate;
    FO2Freq := Freq;
  end;
  ShortWait(100, R);
end;

procedure TPSPAudio.hVaudioChRelease;
begin
  if not FO2Reserved then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_NOT_RESERVED);
    Exit;
  end;
  if FO2Waiter <> nil then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_OUTPUT_BUSY);
    Exit;
  end;
  FHLE.Result(0);
  if (FO2Armed > 0) and FKernel.CanWait then
  begin
    // Drains with a null output, then releases.
    FO2Waiter := FKernel.Current;
    FO2WaitNull := True;
    FO2WaitRelease := True;
    ParkCurrent('audio2');
    Exit;
  end;
  ReleaseOutput2;
  FVaudioBusy := False;
end;

procedure TPSPAudio.hVaudioOutputBlocking;
begin
  var Vol := FHLE.Arg(0);
  if not FO2Reserved then
  begin
    Cost(120);
    FHLE.Result(SCE_AUDIO_ERROR_NOT_RESERVED);
    Exit;
  end;
  if Vol > $FFFFF then
  begin
    FHLE.Result(SCE_AUDIO_ERROR_INVALID_VOLUME);
    Exit;
  end;
  Output2Output(Vol, FHLE.Arg(1));
end;

{ Input }

function TPSPAudio.InputCheck(Samples, Freq: Integer; out Error: Cardinal): Boolean;
begin
  Error := 0;
  if not FInputInit then
    Error := SCE_ERROR_NOT_INIT_INPUT
  else if (Samples <= 0) or ((Samples and 63) <> 0) then
    Error := SCE_AUDIO_ERROR_INVALID_SIZE
  else if (Freq <> 44100) and (Freq <> 22050) and (Freq <> 11025) then
    Error := SCE_AUDIO_ERROR_INVALID_FREQUENCY
  else if FInputBusy then
    Error := SCE_AUDIO_ERROR_OUTPUT_BUSY;
  Result := Error = 0;
end;

procedure TPSPAudio.StartInput(Samples, Freq: Integer; Buffer: Cardinal);
begin
  // No microphone: the capture is silence.
  if Buffer <> 0 then
    FMemory.Fill(Buffer, 0, Cardinal(Samples) * 2);
  FInputBusy := True;
  FInputStart := FScheduler.Now;
  FInputCount := Samples;
  FInputFreq := Freq;
  FInputEnd := FInputStart + Int64(Samples) * 1000000000 div Freq;
  ScheduleNext;
end;

procedure TPSPAudio.FinishInput;
begin
  FInputBusy := False;
  if FInputWaiter <> nil then
  begin
    var T := FInputWaiter;
    FInputWaiter := nil;
    if T.IsWaiting and (T.Wait.HLETag = 'audioin') then
      FKernel.EndWait(T, Cardinal(T.Wait.Data[0]));
  end;
end;

procedure TPSPAudio.hInputInit;
begin
  FInputInit := True;
  ShortWait(100, 0);
end;

procedure TPSPAudio.hInput;
begin
  var Samples := FHLE.ArgInt(0);
  var Freq := FHLE.ArgInt(1);
  var Buffer := FHLE.Arg(2);
  var E: Cardinal;
  if not InputCheck(Samples, Freq, E) then
  begin
    FHLE.Result(E);
    Exit;
  end;
  StartInput(Samples, Freq, Buffer);
  if Buffer = 0 then
    FHLE.Result(0)
  else
    FHLE.Result(Cardinal(Samples));
end;

procedure TPSPAudio.hInputBlocking;
begin
  var Samples := FHLE.ArgInt(0);
  var Freq := FHLE.ArgInt(1);
  var Buffer := FHLE.Arg(2);
  var E: Cardinal;
  if not InputCheck(Samples, Freq, E) then
  begin
    FHLE.Result(E);
    Exit;
  end;
  StartInput(Samples, Freq, Buffer);
  var R := Cardinal(Samples);
  if Buffer = 0 then
    R := 0;
  FHLE.Result(R);
  if not FKernel.CanWait then
    Exit;
  FInputWaiter := FKernel.Current;
  ParkCurrent('audioin');
  if FKernel.Current.Wait.HLETag = 'audioin' then
    FKernel.Current.Wait.Data[0] := R;
end;

procedure TPSPAudio.hGetInputLength;
begin
  if not FInputBusy then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var Done := (FScheduler.Now - FInputStart) * FInputFreq div 1000000000;
  FHLE.Result(Cardinal(Min(Done, Int64(FInputCount))));
end;

procedure TPSPAudio.hWaitInputEnd;
begin
  FHLE.Result(0);
  if not FInputBusy or not FKernel.CanWait or (FInputWaiter <> nil) then
    Exit;
  FInputWaiter := FKernel.Current;
  ParkCurrent('audioin');
  if FKernel.Current.Wait.HLETag = 'audioin' then
    FKernel.Current.Wait.Data[0] := 0;
end;

procedure TPSPAudio.hPollInputEnd;
begin
  if FInputBusy then
    FHLE.Result(1)
  else
    FHLE.Result(0);
end;

{ Routing }

procedure TPSPAudio.hRoutingGetMode;
begin
  FHLE.Result(FRoutingMode);
end;

procedure TPSPAudio.hRoutingSetMode;
begin
  var M := FHLE.Arg(0);
  if M > 3 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE_ROUTING);
    Exit;
  end;
  FHLE.Result(FRoutingMode);
  FRoutingMode := M;
end;

procedure TPSPAudio.hRoutingGetVolumeMode;
begin
  FHLE.Result(FRoutingVolumeMode);
end;

procedure TPSPAudio.hRoutingSetVolumeMode;
begin
  var M := FHLE.Arg(0);
  if M > 1 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE_ROUTING);
    Exit;
  end;
  FRoutingVolumeMode := M;
  FHLE.Result(0);
end;

procedure TPSPAudio.Register;
begin
  var H := FHLE;
  const A = 'sceAudio';
  H.Register(A, $5EC81C55, 'sceAudioChReserve', hChReserve);
  H.Register(A, $6FC46853, 'sceAudioChRelease', hChRelease);
  H.Register(A, $8C1009B2, 'sceAudioOutput', hOutput);
  H.Register(A, $136CAF51, 'sceAudioOutputBlocking', hOutputBlocking);
  H.Register(A, $E2D56B2D, 'sceAudioOutputPanned', hOutputPanned);
  H.Register(A, $13F592BC, 'sceAudioOutputPannedBlocking', hOutputPannedBlocking);
  H.Register(A, $41EFADE7, 'sceAudioOneshotOutput', hOneshotOutput);
  H.Register(A, $E9D97901, 'sceAudioGetChannelRestLen', hGetChannelRestLen);
  H.Register(A, $B011922F, 'sceAudioGetChannelRestLength', hGetChannelRestLength);
  H.Register(A, $CB2E439E, 'sceAudioSetChannelDataLen', hSetChannelDataLen);
  H.Register(A, $95FD0C2D, 'sceAudioChangeChannelConfig', hChangeChannelConfig);
  H.Register(A, $B7E1D8E7, 'sceAudioChangeChannelVolume', hChangeChannelVolume);
  H.Register(A, $01562BA3, 'sceAudioOutput2Reserve', hOutput2Reserve);
  H.Register(A, $2D53F36E, 'sceAudioOutput2OutputBlocking', hOutput2OutputBlocking);
  H.Register(A, $43196845, 'sceAudioOutput2Release', hOutput2Release);
  H.Register(A, $63F2889C, 'sceAudioOutput2ChangeLength', hOutput2ChangeLength);
  H.Register(A, $647CEF33, 'sceAudioOutput2GetRestSample', hOutput2GetRestSample);
  H.Register(A, $38553111, 'sceAudioSRCChReserve', hSRCChReserve);
  H.Register(A, $5C37C0AE, 'sceAudioSRCChRelease', hOutput2Release);
  H.Register(A, $E0727056, 'sceAudioSRCOutputBlocking', hSRCOutputBlocking);
  H.Register(A, $A2BEAA6C, 'sceAudioSetFrequency', hSetFrequency);
  H.Register(A, $927AC32B, 'sceAudioSetVolumeOffset', hZero);
  H.Register(A, $B61595C0, 'sceAudioLoopbackTest', hZero);
  H.Register(A, $7DE61688, 'sceAudioInputInit', hInputInit);
  H.Register(A, $E926D3FB, 'sceAudioInputInitEx', hInputInit);
  H.Register(A, $6D4BEC68, 'sceAudioInput', hInput);
  H.Register(A, $086E5895, 'sceAudioInputBlocking', hInputBlocking);
  H.Register(A, $A708C6A6, 'sceAudioGetInputLength', hGetInputLength);
  H.Register(A, $87B2E651, 'sceAudioWaitInputEnd', hWaitInputEnd);
  H.Register(A, $A633048E, 'sceAudioPollInputEnd', hPollInputEnd);
  const V = 'sceVaudio';
  H.Register(V, $03B6807D, 'sceVaudioChReserve', hVaudioChReserve);
  H.Register(V, $67585DFD, 'sceVaudioChRelease', hVaudioChRelease);
  H.Register(V, $8986295E, 'sceVaudioOutputBlocking', hVaudioOutputBlocking);
  H.Register(V, $346FBE94, 'sceVaudioSetEffectType', hZero);
  H.Register(V, $CBD4AC51, 'sceVaudioSetAlcMode', hZero);
  const R = 'sceAudioRouting';
  H.Register(R, $39240E7D, 'sceAudioRoutingGetMode', hRoutingGetMode);
  H.Register(R, $36FD8AA9, 'sceAudioRoutingSetMode', hRoutingSetMode);
  H.Register(R, $28235C56, 'sceAudioRoutingGetVolumeMode', hRoutingGetVolumeMode);
  H.Register(R, $BB548475, 'sceAudioRoutingSetVolumeMode', hRoutingSetVolumeMode);
end;

initialization
  RegisterPSPService(TPSPAudio);

end.
