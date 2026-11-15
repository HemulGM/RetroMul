unit J2ME.Nokia.Sound;

interface

uses
  System.SysUtils, System.Generics.Collections, JVM.Types, JVM.ClassFile,
  JVM.Runtime, RetroTune.Decoder, J2ME.Nokia.OTA;

type
  TNokiaSoundEvent = record
    Listener, Sound, State: Integer;
  end;

  TNokiaSoundVoice = class
  public
    Reference, State, Gain, Format, Generation, Loops, LoopsLeft: Integer;
    Rooted, HasPlayed, Decoding, SimpleTone: Boolean;
    Order: UInt64;
    Data: TBytes;
    Decoder: ITuneDecoder;
    Info: TTuneInfo;
    PCM: TArray<SmallInt>;
    SampleCount, FrameCount: Integer;
    Position: Int64;
    Song: TNokiaToneSong;
    Pattern, Instruction, Repetition, Scale, Style, Tempo, Volume: Integer;
    ToneLength, SegmentLength, SegmentPosition, SegmentOn: Int64;
    Frequency, Increment, Phase: Double;
    procedure ResetCursor;
    function NextSegment: Boolean;
  end;
  // Owned and used only by the VM/audio executor; no device, JVM-global or FMX state.

  TJ2MENokiaSound = class
  private
    FVM: TJVM;
    FVoices: TObjectDictionary<Integer, TNokiaSoundVoice>;
    FEvents: TQueue<TNokiaSoundEvent>;
    FOrder: UInt64;
    function Voice(Ref: Integer): TNokiaSoundVoice;
    procedure ChangeState(V: TNokiaSoundVoice; State: Integer; Notify: Boolean = True);
    procedure ReleaseVoice(V: TNokiaSoundVoice; Notify: Boolean = True);
    function DecodeStep(V: TNokiaSoundVoice): Boolean;
    procedure StartVoice(V: TNokiaSoundVoice; Resume: Boolean);
    function EndCycle(V: TNokiaSoundVoice): Boolean;
    procedure Sweep;
  public
    constructor Create(VM: TJVM);
    destructor Destroy; override;
    procedure Install;
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    procedure MixInto(var Mix: TArray<Int64>; Frames: Integer);
    function TakeEvent(out Event: TNokiaSoundEvent): Boolean;
    function HasEvents: Boolean;
    procedure ReleaseEvent(const Event: TNokiaSoundEvent);
    procedure Shutdown;
  end;

implementation

uses
  System.Math, Java.Classes, RetroTune.Decoder.WAV;

const
  SoundName = 'com/nokia/mid/sound/Sound';
  ListenerName = 'com/nokia/mid/sound/SoundListener';
  ListenerField = SoundName + '.$listener:Lcom/nokia/mid/sound/SoundListener;';
  MaxVoices = 128;
  ChannelsPerFormat = 16;
  MaxSamples = 8 * 1024 * 1024;
  MaxTotalSamples = 32 * 1024 * 1024;

function MillisecondFrames(Millis: Int64): Int64;
begin
  if Millis > High(Int64) div 44100 * 1000 then
    Exit(High(Int64));
  Result := (Millis div 1000) * 44100 + (Millis mod 1000) * 44100 div 1000;
end;

procedure TNokiaSoundVoice.ResetCursor;
begin
  Position := 0;
  Pattern := 0;
  Instruction := 0;
  Repetition := 0;
  Scale := 1;
  Style := 0;
  Tempo := 63;
  Volume := 7;
  SegmentLength := 0;
  SegmentPosition := 0;
  Phase := 0;
  if SimpleTone then
  begin
    SegmentLength := ToneLength;
    SegmentOn := ToneLength;
    Increment := 2 * Pi * Frequency / 44100;
  end;
end;

function TNokiaSoundVoice.NextSegment: Boolean;
begin
  Result := False;
  while Pattern < Length(Song) do
  begin
    var P := Song[Pattern];
    if Instruction >= Length(P.Instructions) then
    begin
      if (P.Repeats = 15) or (Repetition < P.Repeats) then
      begin
        if P.Repeats <> 15 then
          Inc(Repetition);
        Instruction := 0;
      end
      else
      begin
        Inc(Pattern);
        Instruction := 0;
        Repetition := 0;
      end;
      Continue;
    end;
    var I := P.Instructions[Instruction];
    Inc(Instruction);
    case I.Kind of
      2:
        Scale := I.Value;
      3:
        Style := I.Value;
      4:
        Tempo := NokiaTempo(I.Value);
      5:
        Volume := I.Value;
      1:
        begin
          var Numerator := Int64(44100) * 240;
          var Denominator := Int64(Tempo) * (1 shl I.Duration);
          case I.Modifier of
            1:
              begin
                Numerator := Numerator * 3;
                Denominator := Denominator * 2;
              end;
            2:
              begin
                Numerator := Numerator * 7;
                Denominator := Denominator * 4;
              end;
            3:
              begin
                Numerator := Numerator * 2;
                Denominator := Denominator * 3;
              end;
          end;
          SegmentLength := Max(Int64(1), (Numerator + Denominator div 2) div Denominator);
          SegmentOn := SegmentLength;
          if Style = 0 then
            SegmentOn := SegmentLength * 15 div 16
          else if Style = 2 then
            SegmentOn := SegmentLength div 2;
          Frequency := 0;
          if I.Value <> 0 then
            Frequency := 440 * Power(2, (I.Value - 10 + Scale * 12) / 12);
          Increment := 2 * Pi * Frequency / 44100;
          SegmentPosition := 0;
        // Phase is continuous across legato notes; explicit gaps reset it.
          if Style <> 1 then
            Phase := 0;
          Exit(True);
        end;
    end;
  end;
end;

constructor TJ2MENokiaSound.Create(VM: TJVM);
begin
  inherited Create;
  FVM := VM;
  FVoices := TObjectDictionary<Integer, TNokiaSoundVoice>.Create([doOwnsValues]);
  FEvents := TQueue<TNokiaSoundEvent>.Create;
end;

destructor TJ2MENokiaSound.Destroy;
begin
  Shutdown;
  FEvents.Free;
  FVoices.Free;
  inherited;
end;

procedure TJ2MENokiaSound.Install;
var
  B: TJavaClassBuilder;

  procedure Constant(const N: string; Value: Integer);
  begin
    B.Field(N, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

begin
  B := TJavaClassBuilder.Create(ListenerName, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
  try
    B.JavaClass.AddNative('soundStateChanged', '(Lcom/nokia/mid/sound/Sound;I)V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(SoundName, 'java/lang/Object');
  try
    Constant('FORMAT_TONE', 1);
    Constant('FORMAT_WAV', 5);
    Constant('SOUND_PLAYING', 0);
    Constant('SOUND_STOPPED', 1);
    Constant('SOUND_UNINITIALIZED', 3);
    B.Field('$listener', 'Lcom/nokia/mid/sound/SoundListener;', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('<init>', '([BI)V');
    B.JavaClass.AddNative('<init>', '(IJ)V');
    B.JavaClass.AddNative('init', '([BI)V');
    B.JavaClass.AddNative('init', '(IJ)V');
    B.JavaClass.AddNative('play', '(I)V');
    for var N in ['stop', 'resume', 'release'] do
      B.JavaClass.AddNative(N, '()V');
    for var N in ['getState', 'getGain'] do
      B.JavaClass.AddNative(N, '()I');
    B.JavaClass.AddNative('setGain', '(I)V');
    B.JavaClass.AddNative('setSoundListener', '(Lcom/nokia/mid/sound/SoundListener;)V');
    B.JavaClass.AddNative('getConcurrentSoundCount', '(I)I', True);
    B.JavaClass.AddNative('getSupportedFormats', '()[I', True);
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function TJ2MENokiaSound.Handles(const Owner: string): Boolean;
begin
  Result := Owner = SoundName;
end;

procedure TJ2MENokiaSound.Sweep;
begin
  for var Ref in FVoices.Keys.ToArray do
    if not FVM.IsObjectAlive(Ref) then
      FVoices.Remove(Ref);
end;

function TJ2MENokiaSound.Voice(Ref: Integer): TNokiaSoundVoice;
begin
  FVM.GetObject(Ref);
  if FVoices.TryGetValue(Ref, Result) then
    Exit;
  Sweep;
  if FVoices.Count >= MaxVoices then
    FVM.RaiseJava('java/lang/OutOfMemoryError', 'Nokia sound object limit');
  Result := TNokiaSoundVoice.Create;
  Result.Reference := Ref;
  Result.State := 3;
  Result.Gain := 255;
  FVoices.Add(Ref, Result);
end;

procedure TJ2MENokiaSound.ChangeState(V: TNokiaSoundVoice; State: Integer; Notify: Boolean);
var
  Listener: TJVMValue;
  Event: TNokiaSoundEvent;
begin
  if V.State = State then
    Exit;
  V.State := State;
  if (State = 0) <> V.Rooted then
  begin
    V.Rooted := State = 0;
    if V.Rooted then
      FVM.AddRoot(V.Reference)
    else
      FVM.RemoveRoot(V.Reference);
  end;
  if not Notify or not FVM.GetObject(V.Reference).Fields.TryGetValue(ListenerField, Listener) or (Listener.AsRef = 0) then
    Exit;
  if FEvents.Count >= 65536 then
    FVM.RaiseJava('java/lang/OutOfMemoryError', 'Nokia sound event queue limit');
  Event.Listener := Listener.AsRef;
  Event.Sound := V.Reference;
  Event.State := State;
  FVM.AddRoot(Event.Listener);
  FVM.AddRoot(Event.Sound);
  FEvents.Enqueue(Event);
end;

procedure TJ2MENokiaSound.ReleaseVoice(V: TNokiaSoundVoice; Notify: Boolean);
begin
  if V.State = 0 then
    ChangeState(V, 1, Notify);
  ChangeState(V, 3, Notify);
  Inc(V.Generation);
  V.Decoder := nil;
  V.PCM := nil;
  V.Data := nil;
  V.Song := nil;
  V.SampleCount := 0;
  V.FrameCount := 0;
  V.Decoding := False;
  V.HasPlayed := False;
  V.SimpleTone := False;
  V.Position := 0;
end;

function TJ2MENokiaSound.DecodeStep(V: TNokiaSoundVoice): Boolean;
var
  Samples: TArray<SmallInt>;
  Count, Needed, Capacity, Total: Integer;
begin
  Result := True;
  if V.Decoder = nil then
  begin
    V.Decoder := TTuneDecoders.OpenData(V.Data, '.wav');
    V.Info := V.Decoder.GetInfo;
    if (V.Info.SampleRate < 1) or (V.Info.SampleRate > 384000) or not (V.Info.Channels in [1, 2]) then
      raise ENokiaToneFormat.Create('Unsupported Nokia WAV PCM format');
  end;
  SetLength(Samples, 4096 * V.Info.Channels);
  Count := V.Decoder.Render(Samples, 4096);
  if (Count < 0) or (Count > 4096) then
    raise ENokiaToneFormat.Create('Invalid WAV decoder result');
  Needed := V.SampleCount + Count * V.Info.Channels;
  if Needed > MaxSamples then
    FVM.RaiseJava('java/lang/OutOfMemoryError', 'Nokia decoded clip limit');
  if Needed > Length(V.PCM) then
  begin
    Capacity := Min(MaxSamples, Max(Needed, Max(8192, Length(V.PCM) * 2)));
    Total := Capacity;
    for var Other in FVoices.Values do
      if Other <> V then
        Inc(Total, Length(Other.PCM));
    if Total > MaxTotalSamples then
      FVM.RaiseJava('java/lang/OutOfMemoryError', 'Nokia decoded audio memory limit');
    SetLength(V.PCM, Capacity);
  end;
  if Count > 0 then
    Move(Samples[0], V.PCM[V.SampleCount], Count * V.Info.Channels * SizeOf(SmallInt));
  V.SampleCount := Needed;
  if Count <> 0 then
    Exit(False);
  V.FrameCount := Needed div V.Info.Channels;
  SetLength(V.PCM, Needed);
  V.Decoder := nil;
  V.Data := nil;
  V.Decoding := False;
  ChangeState(V, 1);
end;

procedure TJ2MENokiaSound.StartVoice(V: TNokiaSoundVoice; Resume: Boolean);
begin
  if V.State = 3 then
    Exit;
  if Resume and ((V.State = 0) or not V.HasPlayed) then
    Exit;
  if not Resume then
  begin
    if V.State = 0 then
      ChangeState(V, 1);
    V.ResetCursor;
    V.LoopsLeft := V.Loops;
  end
  else if V.Format = 1 then
    V.ResetCursor;
  var Active := 0;
  var Oldest: TNokiaSoundVoice := nil;
  for var Other in FVoices.Values do
    if (Other.State = 0) and (Other.Format = V.Format) then
    begin
      Inc(Active);
      if (Oldest = nil) or (Other.Order < Oldest.Order) then
        Oldest := Other;
    end;
  if (Active >= ChannelsPerFormat) and (Oldest <> nil) then
    ChangeState(Oldest, 1);
  Inc(FOrder);
  V.Order := FOrder;
  V.HasPlayed := True;
  ChangeState(V, 0);
  if (V.Format = 5) and (V.FrameCount = 0) then
    ChangeState(V, 1)
  else if (V.Format = 1) and not V.SimpleTone and not V.NextSegment then
    ChangeState(V, 1);
end;

function TJ2MENokiaSound.EndCycle(V: TNokiaSoundVoice): Boolean;
begin
  Result := False;
  if (V.LoopsLeft = -1) or (V.LoopsLeft > 1) then
  begin
    if V.LoopsLeft > 1 then
      Dec(V.LoopsLeft);
    V.ResetCursor;
    if (V.Format = 1) and not V.SimpleTone and not V.NextSegment then
    begin
      ChangeState(V, 1);
      Exit;
    end;
    Exit(True);
  end;
  ChangeState(V, 1);
end;

function TJ2MENokiaSound.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  V: TNokiaSoundVoice;
  N: string;
begin
  Result := Default(TJVMValue);
  N := Method.Name;
  if N = 'getSupportedFormats' then
  begin
    var Ref := FVM.NewArray('[I', 2);
    FVM.GetObject(Ref).Elements[0] := TJVMValue.Int(1);
    FVM.GetObject(Ref).Elements[1] := TJVMValue.Int(5);
    Exit(TJVMValue.Ref(Ref));
  end;
  if N = 'getConcurrentSoundCount' then
  begin
    if (Args[0].AsInt <> 1) and (Args[0].AsInt <> 5) then
      FVM.RaiseJava('java/lang/IllegalArgumentException');
    Exit(TJVMValue.Int(ChannelsPerFormat));
  end;
  V := Voice(Args[0].AsRef);
  if N = 'getState' then
    Exit(TJVMValue.Int(V.State));
  if N = 'getGain' then
    Exit(TJVMValue.Int(V.Gain));
  if N = 'setGain' then
  begin
    V.Gain := EnsureRange(Args[1].AsInt, 0, 255);
    Exit;
  end;
  if N = 'setSoundListener' then
  begin
    FVM.GetObject(V.Reference).Fields[ListenerField] := Args[1];
    Exit;
  end;
  if N = 'release' then
  begin
    ReleaseVoice(V);
    Exit;
  end;
  if N = 'stop' then
  begin
    if V.State = 0 then
      ChangeState(V, 1);
    Exit;
  end;
  if N = 'resume' then
  begin
    StartVoice(V, True);
    Exit;
  end;
  if N = 'play' then
  begin
    var Loops := Args[1].AsInt;
    if Loops < 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException');
    V.Loops := Loops;
    if Loops = 0 then
      V.Loops := -1;
    StartVoice(V, False);
    Exit;
  end;
  if (N = '<init>') or (N = 'init') then
  begin
    var Generation := FVM.NativeContinuation;
    if Generation.Kind = TJVMKind.Int then
    begin
      if Generation.AsInt <> V.Generation then
        Exit;
    end
    else
    begin
      ReleaseVoice(V);
      FVM.SetNativeContinuation(TJVMValue.Int(V.Generation));
      try
        if Method.Descriptor = '(IJ)V' then
        begin
          var Freq := Args[1].AsInt;
          var Duration := Args[2].AsLong;
          if (Freq < 0) or (Freq > 13288) or (Duration <= 0) then
            FVM.RaiseJava('java/lang/IllegalArgumentException', 'Tone frequency/duration');
          V.Format := 1;
          V.SimpleTone := True;
          V.Frequency := Freq;
          V.ToneLength := MillisecondFrames(Duration);
          ChangeState(V, 1);
          Exit;
        end;
        var ArrayObject := FVM.GetObject(Args[1].AsRef);
        var Format := Args[2].AsInt;
        if (Format <> 1) and (Format <> 5) then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Nokia sound format');
        if Length(ArrayObject.Elements) > 16 * 1024 * 1024 then
          FVM.RaiseJava('java/lang/OutOfMemoryError', 'Nokia encoded clip limit');
        SetLength(V.Data, Length(ArrayObject.Elements));
        for var I := 0 to High(V.Data) do
          V.Data[I] := Byte(ArrayObject.Elements[I].AsInt);
        V.Format := Format;
        if Format = 1 then
        begin
          V.Song := DecodeNokiaOTA(V.Data);
          V.Data := nil;
          ChangeState(V, 1);
          Exit;
        end;
        if (Length(V.Data) < 12) or (TEncoding.ASCII.GetString(V.Data, 0, 4) <> 'RIFF') or (TEncoding.ASCII.GetString(V.Data, 8, 4) <> 'WAVE') then
          raise ENokiaToneFormat.Create('Invalid Nokia WAV header');
        V.Decoding := True;
      except
        on E: EJVMThrown do
        begin
          ReleaseVoice(V);
          raise;
        end;
        on E: Exception do
        begin
          ReleaseVoice(V);
          FVM.RaiseJava('java/lang/IllegalArgumentException', E.Message);
        end;
      end;
    end;
    if not V.Decoding then
      Exit;
    try
      if not DecodeStep(V) then
      begin
        FVM.YieldCurrent;
        FVM.RetryNative;
      end;
    except
      on E: EJVMThrown do
      begin
        ReleaseVoice(V);
        raise;
      end;
      on E: Exception do
      begin
        ReleaseVoice(V);
        FVM.RaiseJava('java/lang/IllegalArgumentException', E.Message);
      end;
    end;
    Exit;
  end;
  raise EJVMUnsupported.Create(SoundName + '.' + N);
end;

procedure TJ2MENokiaSound.MixInto(var Mix: TArray<Int64>; Frames: Integer);
begin
  if (Frames < 0) or (Frames > 8192) or (Length(Mix) <> Frames * 2) then
    raise EArgumentOutOfRangeException.Create('Nokia audio render block');
  Sweep;
  for var V in FVoices.Values do
    if V.State = 0 then
    begin
      for var I := 0 to Frames - 1 do
      begin
        if V.State <> 0 then
          Break;
        if V.Format = 5 then
        begin
          if V.Position >= Int64(V.FrameCount) * 44100 then
            if not EndCycle(V) then
              Break;
          var Source := Integer(V.Position div 44100);
          var Fraction := V.Position mod 44100;
          var Next := Min(Source + 1, V.FrameCount - 1);
          for var C := 0 to 1 do
          begin
            var Channel := Min(C, V.Info.Channels - 1);
            var A := V.PCM[Source * V.Info.Channels + Channel];
            var B := V.PCM[Next * V.Info.Channels + Channel];
            var Sample := (Int64(A) * (44100 - Fraction) + Int64(B) * Fraction) div 44100;
            Inc(Mix[I * 2 + C], Sample * V.Gain div 255);
          end;
          Inc(V.Position, V.Info.SampleRate);
          if V.Position >= Int64(V.FrameCount) * 44100 then
          begin
            V.Position := Int64(V.FrameCount) * 44100;
            EndCycle(V);
          end;
        end
        else
        begin
          if V.SegmentPosition >= V.SegmentLength then
          begin
            if V.SimpleTone then
            begin
              if not EndCycle(V) then
                Break;
            end
            else if not V.NextSegment then
              if not EndCycle(V) then
                Break;
          end;
          var Sample := Int64(0);
          var Volume := V.Volume;
          if V.SimpleTone then
            Volume := 15;
          if (V.SegmentPosition < V.SegmentOn) and (V.Frequency <> 0) then
            Sample := Round(Sin(V.Phase) * 16384 * Volume / 15);
          Sample := Sample * V.Gain div 255;
          Inc(Mix[I * 2], Sample);
          Inc(Mix[I * 2 + 1], Sample);
          V.Phase := V.Phase + V.Increment;
          if V.Phase >= 2 * Pi then
            V.Phase := V.Phase - 2 * Pi;
          Inc(V.SegmentPosition);
          if V.SegmentPosition >= V.SegmentLength then
          begin
            if V.SimpleTone then
              EndCycle(V)
            else if not V.NextSegment then
              EndCycle(V);
          end;
        end;
      end;
    end;
end;

function TJ2MENokiaSound.TakeEvent(out Event: TNokiaSoundEvent): Boolean;
begin
  Result := FEvents.Count <> 0;
  if Result then
    Event := FEvents.Dequeue;
end;

function TJ2MENokiaSound.HasEvents: Boolean;
begin
  Result := FEvents.Count <> 0;
end;

procedure TJ2MENokiaSound.ReleaseEvent(const Event: TNokiaSoundEvent);
begin
  FVM.RemoveRoot(Event.Listener);
  FVM.RemoveRoot(Event.Sound);
end;

procedure TJ2MENokiaSound.Shutdown;
begin
  while FEvents.Count <> 0 do
    ReleaseEvent(FEvents.Dequeue);
  for var V in FVoices.Values do
    ReleaseVoice(V, False);
end;

end.

