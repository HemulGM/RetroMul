unit NES.AudioDiagnostics;

interface

uses
  System.SysUtils, System.Classes, System.Diagnostics, NES.Console, PCM.Audio;

const
  AUDIO_DIAGNOSTIC_FRAMES = 1800;

type
  TAudioDiagnosticFrame = record
    Ticks: Int64;
    CpuCycle: Cardinal;
    Pc, Status: Integer;
    P1Length, P2Length, TriLength, NoiseLength, TriLinear: Integer;
    P1Reg0, P2Reg0, TriReg0, NoiseReg0, DmcLevel: Integer;
    Writes: UInt64;
    Queue: TPCMAudioQueueState;
    Count: Integer;
    Samples: TArray<SmallInt>;
  end;

  TAudioDiagnostics = class
  private
    FFrames: TArray<TAudioDiagnosticFrame>;
    FNext, FCount: Integer;
    FSampleRate: Integer;
    FBlockFrames: Integer;
  public
    constructor Create(const AudioFormat: TPCMAudioFormat);
    procedure Clear;
    function Clone: TAudioDiagnostics;
    procedure Capture(Console: TNesConsole; Audio: TPCMAudio; const Samples: array of SmallInt; Count: Integer);
    procedure Save(const Prefix, RomPath, AudioError: string);
    property Count: Integer read FCount;
  end;

implementation

constructor TAudioDiagnostics.Create(const AudioFormat: TPCMAudioFormat);
begin
  inherited Create;
  if (AudioFormat.SampleRate <= 0) or (AudioFormat.Channels <> 1) or
    (AudioFormat.BlockFrames <= 0) then
    raise EArgumentException.Create('Audio diagnostics requires a mono PCM format with a positive sample rate and block size');
  FSampleRate := AudioFormat.SampleRate;
  FBlockFrames := AudioFormat.BlockFrames;
  SetLength(FFrames, AUDIO_DIAGNOSTIC_FRAMES);
  for var i := 0 to High(FFrames) do
    SetLength(FFrames[i].Samples, FBlockFrames);
end;

procedure TAudioDiagnostics.Clear;
begin
  FNext := 0;
  FCount := 0;
end;

function TAudioDiagnostics.Clone: TAudioDiagnostics;
begin
  var AudioFormat := Default(TPCMAudioFormat);
  AudioFormat.SampleRate := FSampleRate;
  AudioFormat.Channels := 1;
  AudioFormat.BlockFrames := FBlockFrames;
  Result := TAudioDiagnostics.Create(AudioFormat);
  try
    Result.FSampleRate := FSampleRate;
    Result.FBlockFrames := FBlockFrames;
    Result.FFrames := Copy(FFrames);
    for var i := 0 to High(Result.FFrames) do
      Result.FFrames[i].Samples := Copy(FFrames[i].Samples);
    Result.FNext := FNext;
    Result.FCount := FCount;
  except
    Result.Free;
    raise;
  end;
end;

procedure TAudioDiagnostics.Capture(Console: TNesConsole; Audio: TPCMAudio; const Samples: array of SmallInt; Count: Integer);
begin
  if (Count < 0) or (Count > Length(Samples)) or (Count > FBlockFrames) then
    raise EArgumentOutOfRangeException.Create('Diagnostic audio block is too large');
  var Frame: ^TAudioDiagnosticFrame := @FFrames[FNext];
  Frame.Ticks := TStopwatch.GetTimeStamp;
  Frame.CpuCycle := Console.Apu.DebugCycle;
  Frame.Pc := Console.Cpu.Pc;
  Frame.Status := Console.Apu.DebugStatus;
  Frame.P1Length := Console.Apu.DebugPulse1Length;
  Frame.P2Length := Console.Apu.DebugPulse2Length;
  Frame.TriLength := Console.Apu.DebugTriangleLength;
  Frame.NoiseLength := Console.Apu.DebugNoiseLength;
  Frame.TriLinear := Console.Apu.DebugTriangle.LinearCounter;
  Frame.P1Reg0 := Console.Apu.DebugPulse1.Reg0;
  Frame.P2Reg0 := Console.Apu.DebugPulse2.Reg0;
  Frame.TriReg0 := Console.Apu.DebugTriangle.Reg0;
  Frame.NoiseReg0 := Console.Apu.DebugNoise.Reg0;
  Frame.DmcLevel := Console.Apu.DebugDmc.OutputLevel;
  Frame.Writes := 0;
  for var address := $4000 to $4017 do
    Inc(Frame.Writes, Console.Apu.DebugWriteCount(address));
  Frame.Queue := Audio.QueueState;
  Frame.Count := Count;
  if Count > 0 then
    Move(Samples[0], Frame.Samples[0], Count * SizeOf(SmallInt));
  FNext := (FNext + 1) mod Length(FFrames);
  if FCount < Length(FFrames) then
    Inc(FCount);
end;

procedure TAudioDiagnostics.Save(const Prefix, RomPath, AudioError: string);
const
  RIFF_CHUNK_ID: AnsiString = 'RIFF';
  WAVE_FORMAT_ID: AnsiString = 'WAVEfmt ';
  DATA_CHUNK_ID: AnsiString = 'data';
begin
  var FirstFrameIndex: Integer := (FNext - FCount + Length(FFrames)) mod Length(FFrames);
  var TotalSamples: Cardinal := 0;
  for var i := 0 to FCount - 1 do
    Inc(TotalSamples, FFrames[(FirstFrameIndex + i) mod Length(FFrames)].Count);
  var Info: TStreamWriter := TStreamWriter.Create(Prefix + '.txt', False, TEncoding.UTF8);
  try
    Info.WriteLine('ROM: ' + RomPath);
    Info.WriteLine('Executable: ' + ParamStr(0));
    Info.WriteLine('Captured: ' + DateTimeToStr(Now));
    Info.WriteLine('Audio error: ' + AudioError);
    Info.WriteLine('WAV contains APU output before the audio backend; it is not a microphone or loopback recording.');
    Info.WriteLine('CSV counters are cumulative; clears increments when playback position resets.');
  finally
    Info.Free;
  end;
  var Log: TStreamWriter := TStreamWriter.Create(Prefix + '.csv', False, TEncoding.UTF8);
  try
    var Wave: TFileStream := TFileStream.Create(Prefix + '.wav', fmCreate);
    try
      var ChunkSize: Cardinal;
      var HeaderWord: Word;
      Wave.WriteBuffer(RIFF_CHUNK_ID[1], 4);
      ChunkSize := 36 + TotalSamples * 2;
      Wave.WriteBuffer(ChunkSize, 4);
      Wave.WriteBuffer(WAVE_FORMAT_ID[1], 8);
      ChunkSize := 16;
      Wave.WriteBuffer(ChunkSize, 4);
      HeaderWord := 1;
      Wave.WriteBuffer(HeaderWord, 2);
      Wave.WriteBuffer(HeaderWord, 2);
      ChunkSize := FSampleRate;
      Wave.WriteBuffer(ChunkSize, 4);
      ChunkSize := FSampleRate * 2;
      Wave.WriteBuffer(ChunkSize, 4);
      HeaderWord := 2;
      Wave.WriteBuffer(HeaderWord, 2);
      HeaderWord := 16;
      Wave.WriteBuffer(HeaderWord, 2);
      Wave.WriteBuffer(DATA_CHUNK_ID[1], 4);
      ChunkSize := TotalSamples * 2;
      Wave.WriteBuffer(ChunkSize, 4);
      Log.WriteLine('host_ms,cpu_cycle,pc,samples,peak,rms,apu_writes,apu_status,p1_len,p2_len,tri_len,noise_len,tri_linear,p1_reg0,p2_reg0,tri_reg0,noise_reg0,dmc_level,device_open,queued_blocks,submitted,dropped,clears,position_known,played');
      var StartTicks: Int64 := FFrames[FirstFrameIndex].Ticks;
      for var i := 0 to FCount - 1 do
      begin
        var Frame: ^TAudioDiagnosticFrame := @FFrames[(FirstFrameIndex + i) mod Length(FFrames)];
        var Peak: Integer := 0;
        var SumSquares: Double := 0;
        for var j := 0 to Frame.Count - 1 do
        begin
          if Abs(Integer(Frame.Samples[j])) > Peak then
            Peak := Abs(Integer(Frame.Samples[j]));
          SumSquares := SumSquares + Sqr(Double(Frame.Samples[j]));
        end;
        if Frame.Count > 0 then
        begin
          Wave.WriteBuffer(Frame.Samples[0], Frame.Count * 2);
          SumSquares := Sqrt(SumSquares / Frame.Count);
        end;
        Log.WriteLine(Format('%d,%d,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d',
            [(Frame.Ticks - StartTicks) * 1000 div TStopwatch.Frequency, Frame.CpuCycle, IntToHex(Frame.Pc, 4), Frame.Count, Peak, Round(SumSquares),
              Frame.Writes, Frame.Status, Frame.P1Length, Frame.P2Length, Frame.TriLength, Frame.NoiseLength, Frame.TriLinear,
              Frame.P1Reg0, Frame.P2Reg0, Frame.TriReg0, Frame.NoiseReg0, Frame.DmcLevel, Ord(Frame.Queue.DeviceOpen), Frame.Queue.QueuedBlocks,
              Frame.Queue.SubmittedSamples, Frame.Queue.DroppedSamples, Frame.Queue.Clears, Ord(Frame.Queue.PositionKnown), Frame.Queue.PlayedSamples]));
      end;
    finally
      Wave.Free;
    end;
  finally
    Log.Free;
  end;
end;

end.

