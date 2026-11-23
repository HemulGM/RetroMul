unit Core.Microphone;

interface

uses
  System.SysUtils, System.SyncObjs;

const
  // Device backends convert their native format to signed 16-bit mono PCM.
  MICROPHONE_SAMPLE_RATE = 44100;
  MICROPHONE_BUFFER_SAMPLES = MICROPHONE_SAMPLE_RATE div 10;

type
  // One reader per source. No host UI, device handles or console-specific input.
  IMicrophoneSource = interface
    ['{C8044346-9C83-40AA-9DC7-8F0D69BE448F}']
    // Nonblocking. Returns available samples and pads the remainder with silence.
    function ReadSamples(var Samples: array of SmallInt): Integer;
    // Discard audio when pausing, resetting or disconnecting a device.
    procedure Clear;
  end;

  IMicrophoneSink = interface
    ['{5FA97409-C4D1-4875-9232-371EAA6E10D1}']
    // Called by the device capture thread; the caller retains its buffer.
    procedure SubmitSamples(const Samples: array of SmallInt);
  end;

  // Optional capability exposed by emulation adapters (Sega CD, NES, etc.).
  // A nil source disconnects the microphone. Capturing devices remains a host task.
  IEmulationMicrophoneInput = interface
    ['{ABBB0049-3AB1-4789-BEBD-DFAE7628AC88}']
    procedure SetMicrophoneSource(const Source: IMicrophoneSource);
  end;

  TBufferedMicrophone = class(TInterfacedObject, IMicrophoneSource, IMicrophoneSink)
  private
    FLock: TCriticalSection;
    FBuffer: TArray<SmallInt>;
    FHead, FCount: Integer;
  public
    constructor Create(Capacity: Integer = MICROPHONE_BUFFER_SAMPLES);
    destructor Destroy; override;
    procedure SubmitSamples(const Samples: array of SmallInt);
    function ReadSamples(var Samples: array of SmallInt): Integer;
    procedure Clear;
  end;

function OpenHostMicrophone: IMicrophoneSource;

implementation

{$IF Defined(MSWINDOWS)}
uses
  Winapi.MMSystem, PCM.Audio.Windows.MMSystem;
{$ELSEIF Defined(LINUX) and not Defined(ANDROID)}

uses
  PCM.Audio.Backend, PCM.Audio.Linux.Alsa, PCM.Audio.Linux.PulseAudio;
{$ELSEIF Defined(MACOS) and not Defined(IOS)}

uses
  System.Math, Macapi.AVFoundation, PCM.Audio.Backend,
  PCM.Audio.Apple.AudioQueue;
{$ENDIF}

const
  CAPTURE_BUFFER_SAMPLES = 256;

{$IF Defined(MSWINDOWS)}
type
  EWaveInput = class(Exception);

  TWaveInputMicrophone = class(TInterfacedObject, IMicrophoneSource)
  private
    FDevice: HWAVEIN;
    FBuffers: array[0..3, 0..CAPTURE_BUFFER_SAMPLES - 1] of SmallInt;
    FHeaders: array[0..3] of TWaveHdr;
    FReadBuffer, FReadOffset: Integer;
    FRunning: Boolean;
  public
    constructor Create(DeviceId: Cardinal);
    destructor Destroy; override;
    function ReadSamples(var Samples: array of SmallInt): Integer;
    procedure Clear;
  end;

constructor TWaveInputMicrophone.Create(DeviceId: Cardinal);
begin
  inherited Create;
  var Format := Default(TWaveFormatEx);
  Format.wFormatTag := WAVE_FORMAT_PCM;
  Format.nChannels := 1;
  Format.nSamplesPerSec := MICROPHONE_SAMPLE_RATE;
  Format.nBlockAlign := SizeOf(SmallInt);
  Format.nAvgBytesPerSec := Format.nSamplesPerSec * Format.nBlockAlign;
  Format.wBitsPerSample := 16;
  if waveInOpen(@FDevice, DeviceId, @Format, 0, 0, CALLBACK_NULL) <> MMSYSERR_NOERROR then
  begin
    FDevice := 0;
    raise EWaveInput.Create('Microphone unavailable');
  end;
  for var Index := Low(FHeaders) to High(FHeaders) do
  begin
    FHeaders[Index].lpData := PAnsiChar(@FBuffers[Index, 0]);
    FHeaders[Index].dwBufferLength := SizeOf(FBuffers[Index]);
    if waveInPrepareHeader(FDevice, @FHeaders[Index], SizeOf(TWaveHdr)) <> MMSYSERR_NOERROR then
      raise EWaveInput.Create('Cannot prepare microphone buffer');
  end;
  Clear;
  if not FRunning then
    raise EWaveInput.Create('Cannot start microphone capture');
end;

destructor TWaveInputMicrophone.Destroy;
begin
  if FDevice <> 0 then
  begin
    waveInReset(FDevice);
    for var Index := Low(FHeaders) to High(FHeaders) do
      if (FHeaders[Index].dwFlags and WHDR_PREPARED) <> 0 then
        waveInUnprepareHeader(FDevice, @FHeaders[Index], SizeOf(TWaveHdr));
    waveInClose(FDevice);
  end;
  inherited;
end;

procedure TWaveInputMicrophone.Clear;
begin
  FRunning := False;
  FReadBuffer := 0;
  FReadOffset := 0;
  if waveInReset(FDevice) <> MMSYSERR_NOERROR then
    Exit;
  for var Index := Low(FHeaders) to High(FHeaders) do
    if waveInAddBuffer(FDevice, @FHeaders[Index], SizeOf(TWaveHdr)) <> MMSYSERR_NOERROR then
      Exit;
  FRunning := waveInStart(FDevice) = MMSYSERR_NOERROR;
end;

function TWaveInputMicrophone.ReadSamples(var Samples: array of SmallInt): Integer;
begin
  Result := 0;
  while FRunning and (Result < Length(Samples)) and ((FHeaders[FReadBuffer].dwFlags and WHDR_DONE) <> 0) do
  begin
    var Limit := Integer(FHeaders[FReadBuffer].dwBytesRecorded div SizeOf(SmallInt));
    if FReadOffset < Limit then
    begin
      Samples[Result] := FBuffers[FReadBuffer, FReadOffset];
      Inc(FReadOffset);
      Inc(Result);
    end
    else
    begin
      FRunning := waveInAddBuffer(FDevice, @FHeaders[FReadBuffer], SizeOf(TWaveHdr)) = MMSYSERR_NOERROR;
      FReadBuffer := (FReadBuffer + 1) mod Length(FHeaders);
      FReadOffset := 0;
    end;
  end;
  for var Index := Result to High(Samples) do
    Samples[Index] := 0;
end;

function TryOpenMicrophone(DeviceId: Cardinal): IMicrophoneSource;
begin
  try
    Result := TWaveInputMicrophone.Create(DeviceId);
  except
    on E: EWaveInput do
      Result := nil;
  end;
end;
{$ELSEIF Defined(LINUX) and not Defined(ANDROID)}

type
  TLinuxMicrophone = class(TInterfacedObject, IMicrophoneSource)
  private
    FApi: TAlsaApi;
    FModule: HMODULE;
    FDevice: Pointer;
    FRunning: Boolean;
    FPulse: TPulseAudioStream;
    function OpenAlsa(const DeviceName: UTF8String): Boolean;
    function OpenPulse(const DeviceName: string): Boolean;
    procedure CloseAlsa;
  public
    function Open(const EndpointId: string): Boolean;
    destructor Destroy; override;
    function ReadSamples(var Samples: array of SmallInt): Integer;
    procedure Clear;
  end;

function TLinuxMicrophone.OpenAlsa(const DeviceName: UTF8String): Boolean;
begin
  Result := False;
  var Error: string;
  if FModule = 0 then
    if not LoadAlsa(FApi, FModule, Error) then
      Exit;
  if not Assigned(FApi.ReadInterleaved) then
    Exit;
  if FApi.Open(FDevice, PAnsiChar(DeviceName), SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK) < 0 then
  begin
    FDevice := nil;
    Exit;
  end;
  FRunning := (FApi.SetParams(FDevice, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
    1, MICROPHONE_SAMPLE_RATE, 1, 60000) >= 0) and (FApi.Start(FDevice) >= 0);
  if not FRunning then
    CloseAlsa;
  Result := FRunning;
end;

function TLinuxMicrophone.OpenPulse(const DeviceName: string): Boolean;
begin
  var Format: TPCMAudioFormat;
  Format.SampleRate := MICROPHONE_SAMPLE_RATE;
  Format.Channels := 1;
  Format.BlockFrames := CAPTURE_BUFFER_SAMPLES;
  Format.BlockCount := MICROPHONE_BUFFER_SAMPLES div CAPTURE_BUFFER_SAMPLES;
  FPulse := TPulseAudioStream.Open(TAudioDeviceKind.Capture, Format, DeviceName);
  Result := FPulse <> nil;
end;

function TLinuxMicrophone.Open(const EndpointId: string): Boolean;
begin
  if EndpointId.StartsWith(PULSE_ENDPOINT_PREFIX) then
  begin
    if OpenPulse(EndpointId.Substring(Length(PULSE_ENDPOINT_PREFIX))) then
      Exit(True);
  end
  else if EndpointId.StartsWith(ALSA_ENDPOINT_PREFIX) then
    if OpenAlsa(UTF8String(EndpointId.Substring(Length(ALSA_ENDPOINT_PREFIX)))) then
      Exit(True);
  Result := OpenAlsa('default') or OpenPulse('');
end;

procedure TLinuxMicrophone.CloseAlsa;
begin
  if FDevice <> nil then
  begin
    FApi.Drop(FDevice);
    FApi.Close(FDevice);
    FDevice := nil;
  end;
  FRunning := False;
end;

destructor TLinuxMicrophone.Destroy;
begin
  FPulse.Free;
  CloseAlsa;
  if FModule <> 0 then
    FreeLibrary(FModule);
  inherited;
end;

procedure TLinuxMicrophone.Clear;
begin
  if FPulse <> nil then
    FPulse.Clear
  else if FDevice <> nil then
    FRunning := (FApi.Drop(FDevice) >= 0) and (FApi.Prepare(FDevice) >= 0) and (FApi.Start(FDevice) >= 0);
end;

function TLinuxMicrophone.ReadSamples(var Samples: array of SmallInt): Integer;
begin
  if FPulse <> nil then
    Exit(FPulse.Read(Samples));
  Result := 0;
  if Length(Samples) = 0 then
    Exit;
  if FRunning then
  begin
    var Count := FApi.ReadInterleaved(FDevice, @Samples[0], Length(Samples));
    if Count >= 0 then
      Result := Count
    else if (Count = -ALSA_EPIPE) or (Count = -ALSA_ESTRPIPE) then
      FRunning := (FApi.Prepare(FDevice) >= 0) and (FApi.Start(FDevice) >= 0)
    else if (Count <> -ALSA_EAGAIN) and (Count <> -ALSA_EINTR) then
      CloseAlsa;
  end;
  if Result < Length(Samples) then
    FillChar(Samples[Result], (Length(Samples) - Result) * SizeOf(SmallInt), 0);
end;

{$ELSEIF Defined(MACOS) and not Defined(IOS)}
type
  TAppleMicrophone = class(TInterfacedObject, IMicrophoneSource)
  private
    FQueue: Pointer;
    FBuffer: TBufferedMicrophone;
    FEndpointId: string;
    FWaitingForPermission: Boolean;
    procedure OpenQueue;
    class procedure PermissionResolved(Granted: Boolean);
    class procedure BufferReady(UserData, Queue: Pointer; Buffer: PAppleQueueBuffer; StartTime: Pointer; PacketCount: Cardinal; Packets: Pointer); static; cdecl;
    class var
      FPermissionPending: Integer;
  public
    constructor Create(const EndpointId: string);
    destructor Destroy; override;
    function ReadSamples(var Samples: array of SmallInt): Integer;
    procedure Clear;
  end;

constructor TAppleMicrophone.Create(const EndpointId: string);
begin
  inherited Create;
  FBuffer := TBufferedMicrophone.Create;
  FEndpointId := EndpointId;
  case TAVCaptureDevice.OCClass.authorizationStatusForMediaType(AVMediaTypeAudio) of
    AVAuthorizationStatusAuthorized:
      OpenQueue;
    AVAuthorizationStatusNotDetermined:
      begin
        FWaitingForPermission := True;
        if TInterlocked.CompareExchange(FPermissionPending, 1, 0) = 0 then
          TAVCaptureDevice.OCClass.requestAccessForMediaType(AVMediaTypeAudio, PermissionResolved);
      end;
  end;
end;

class procedure TAppleMicrophone.PermissionResolved(Granted: Boolean);
begin
  // The system can respond after the emulation session has stopped.
  TInterlocked.Exchange(FPermissionPending, 0);
end;

procedure TAppleMicrophone.OpenQueue;
begin
  FQueue := OpenAppleInputQueue(FEndpointId, MICROPHONE_SAMPLE_RATE, CAPTURE_BUFFER_SAMPLES, BufferReady, Self);
  if (FQueue = nil) and (FEndpointId <> '') then
    FQueue := OpenAppleInputQueue('', MICROPHONE_SAMPLE_RATE, CAPTURE_BUFFER_SAMPLES, BufferReady, Self);
end;

destructor TAppleMicrophone.Destroy;
begin
  CloseAppleInputQueue(FQueue);
  FBuffer.Free;
  inherited;
end;

class procedure TAppleMicrophone.BufferReady(UserData, Queue: Pointer; Buffer: PAppleQueueBuffer; StartTime: Pointer; PacketCount: Cardinal; Packets: Pointer);
type
  TInputSamples = array[0..CAPTURE_BUFFER_SAMPLES - 1] of SmallInt;

  PInputSamples = ^TInputSamples;
begin
  var Count := Min(CAPTURE_BUFFER_SAMPLES, Integer(Buffer.ByteSize div SizeOf(SmallInt)));
  if Count > 0 then
    TAppleMicrophone(UserData).FBuffer.SubmitSamples(Slice(PInputSamples(Buffer.Data)^, Count));
  RecycleAppleInputBuffer(Queue, Buffer);
end;

procedure TAppleMicrophone.Clear;
begin
  FBuffer.Clear;
end;

function TAppleMicrophone.ReadSamples(var Samples: array of SmallInt): Integer;
begin
  if FWaitingForPermission and (TInterlocked.CompareExchange(FPermissionPending, 0, 0) = 0) then
  begin
    FWaitingForPermission := False;
    if TAVCaptureDevice.OCClass.authorizationStatusForMediaType(AVMediaTypeAudio) = AVAuthorizationStatusAuthorized then
      OpenQueue;
  end;
  Result := FBuffer.ReadSamples(Samples);
end;
{$ENDIF}

function OpenHostMicrophone: IMicrophoneSource;
begin
  {$IF Defined(MSWINDOWS)}
  var DeviceId := PreferredWaveAudioDevice(TWaveAudioDeviceKind.Capture);
  Result := TryOpenMicrophone(DeviceId);
  if (Result = nil) and (DeviceId <> WAVE_MAPPER) then
    Result := TryOpenMicrophone(WAVE_MAPPER);
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID)}
  var Revision: Integer;
  var Source := TLinuxMicrophone.Create;
  try
    if not Source.Open(PreferredAudioEndpoint(TAudioDeviceKind.Capture, Revision)) then
      Exit(nil);
    Result := Source;
    Source := nil;
  finally
    Source.Free;
  end;
  {$ELSEIF Defined(MACOS) and not Defined(IOS)}
  var Revision: Integer;
  var Source := TAppleMicrophone.Create(PreferredAudioEndpoint(TAudioDeviceKind.Capture, Revision));
  if (Source.FQueue <> nil) or Source.FWaitingForPermission then
    Result := Source
  else
  begin
    Source.Free;
    Result := nil;
  end;
  {$ELSE}
  Result := nil;
  {$ENDIF}
end;

constructor TBufferedMicrophone.Create(Capacity: Integer);
begin
  inherited Create;
  if (Capacity < 1) or (Capacity > MICROPHONE_SAMPLE_RATE) then
    raise EArgumentOutOfRangeException.Create('Microphone buffer capacity must be 1..44100 samples');

  FLock := TCriticalSection.Create;
  SetLength(FBuffer, Capacity);
end;

destructor TBufferedMicrophone.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TBufferedMicrophone.SubmitSamples(const Samples: array of SmallInt);
begin
  FLock.Acquire;
  try
    // Keep the newest audio on overflow: bounded latency after a slow frame.
    var First := 0;
    if Length(Samples) > Length(FBuffer) then
      First := Length(Samples) - Length(FBuffer);
    for var i := First to High(Samples) do
    begin
      if FCount = Length(FBuffer) then
      begin
        FHead := (FHead + 1) mod Length(FBuffer);
        Dec(FCount);
      end;
      FBuffer[(FHead + FCount) mod Length(FBuffer)] := Samples[i];
      Inc(FCount);
    end;
  finally
    FLock.Release;
  end;
end;

function TBufferedMicrophone.ReadSamples(var Samples: array of SmallInt): Integer;
begin
  FLock.Acquire;
  try
    Result := Length(Samples);
    if Result > FCount then
      Result := FCount;
    for var i := 0 to Result - 1 do
      Samples[i] := FBuffer[(FHead + i) mod Length(FBuffer)];
    FHead := (FHead + Result) mod Length(FBuffer);
    Dec(FCount, Result);
    for var i := Result to High(Samples) do
      Samples[i] := 0;
  finally
    FLock.Release;
  end;
end;

procedure TBufferedMicrophone.Clear;
begin
  FLock.Acquire;
  try
    FHead := 0;
    FCount := 0;
  finally
    FLock.Release;
  end;
end;

end.

