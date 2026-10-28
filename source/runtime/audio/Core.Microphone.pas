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

implementation

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

