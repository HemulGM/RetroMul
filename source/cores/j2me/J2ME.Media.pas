unit J2ME.Media;

interface

uses
  Audio.Types, System.Classes, JVM.StateIO, System.SysUtils,
  System.Generics.Collections, JVM.Types, JVM.ClassFile, JVM.Runtime,
  Audio.Decoder;

type
  TJ2MEMediaEvent = record
    Listener, Player, EventName, Data: Integer;
  end;

  TJ2MEMediaPlayer = class
  public
    Reference, State, Volume, LoopCount, LoopsLeft, Generation: Integer;
    Muted, Decoding, Rooted, Streaming: Boolean;
    ContentType: string;
    Data: TBytes;
    Decoder: IAudioSource;
    Info: TAudioInfo;
    PCM: TArray<SmallInt>;
    SampleCount: Integer;
    FrameCount, CacheFrame, DecoderFrame: Int64;
    Position: Int64; // Source-frame position in 1/44100 frame units.
    procedure DiscardDecodedAudio;
    function MediaTime: Int64;
    function Duration: Int64;
  end;

  TJ2METone = record
    Remaining: Int64;
    Phase, Increment: Double;
    Volume: Integer;
  end;
  // One owner, the Java/emulation thread. No device or FMX dependency.

  TJ2MEMedia = class
  private
    FVM: TJVM;
    FPlayers: TObjectDictionary<Integer, TJ2MEMediaPlayer>;
    FEvents: TQueue<TJ2MEMediaEvent>;
    FTones: TList<TJ2METone>;
    FClockFrames: Int64;
    FTimeBase: Integer;
    FSeenGC: UInt64;
    FDecodeBuffer: TArray<SmallInt>;
    function Player(Ref: Integer; AllowClosed: Boolean = False): TJ2MEMediaPlayer;
    function CreatePlayer(const Data: TBytes; const ContentType: string): Integer;
    function RealizeStep(P: TJ2MEMediaPlayer; Generation: Integer): Boolean;
    procedure ReadStream(P: TJ2MEMediaPlayer; Source, Next: Int64);
    procedure PostEvent(P: TJ2MEMediaPlayer; const Name: string; Data: Integer);
    procedure TimeEvent(P: TJ2MEMediaPlayer; const Name: string; Time: Int64);
    procedure SetStarted(P: TJ2MEMediaPlayer; Started: Boolean);
    procedure EndOfMedia(P: TJ2MEMediaPlayer);
    procedure Sweep;
  public
    procedure TransferState(S: TJVMStateIO);
    constructor Create(VM: TJVM);
    destructor Destroy; override;
    procedure Install;
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function Render(Frames: Integer): TArray<SmallInt>;
    procedure RenderMixInto(var Mix: TArray<Int64>; Frames: Integer);
    function RenderMix(Frames: Integer): TArray<Int64>;
    function TakeEvent(out Event: TJ2MEMediaEvent): Boolean;
    procedure ReleaseEvent(const Event: TJ2MEMediaEvent);
    procedure ClearEvents;
    procedure Shutdown;
  end;

implementation

uses
  J2ME.Audio.State, System.Math, Java.Classes, Java.Bootstrap, Audio.Format.WAV,
  Audio.Format.MIDI;

{$R 'J2ME.SoundFont.res' 'J2ME.SoundFont.rc'}

{$Q-}{$R-}

const
  Media = 'javax/microedition/media/';
  PlayerAPI = Media + 'Player';
  PlayerImpl = 'org/retromul/media/Player';
  Manager = Media + 'Manager';
  Controllable = Media + 'Controllable';
  Control = Media + 'Control';
  VolumeAPI = Media + 'control/VolumeControl';
  VolumeImpl = 'org/retromul/media/VolumeControl';
  Listener = Media + 'PlayerListener';
  TimeBase = Media + 'TimeBase';
  TimeBaseImpl = 'org/retromul/media/TimeBase';
  PlayerDesc = 'Ljavax/microedition/media/Player;';
  VolumeDesc = 'Ljavax/microedition/media/control/VolumeControl;';
  MaxClipSamples = 8 * 1024 * 1024;
  MaxTotalSamples = 32 * 1024 * 1024;

procedure TJ2MEMediaPlayer.DiscardDecodedAudio;
begin
  Decoder := nil;
  PCM := nil;
  SampleCount := 0;
  FrameCount := 0;
  Position := 0;
  Decoding := False;
  Streaming := False;
  CacheFrame := 0;
  DecoderFrame := 0;
end;

function TJ2MEMediaPlayer.MediaTime: Int64;
begin
  Result := 0;
  if Info.SampleRate > 0 then
    Result := Position * 1000000 div (Int64(44100) * Info.SampleRate);
end;

function TJ2MEMediaPlayer.Duration: Int64;
begin
  Result := -1;
  if State >= 200 then
    Result := Int64(FrameCount) * 1000000 div Info.SampleRate;
end;

constructor TJ2MEMedia.Create(VM: TJVM);
begin
  inherited Create;
  FVM := VM;
  FSeenGC := High(UInt64);
  FPlayers := TObjectDictionary<Integer, TJ2MEMediaPlayer>.Create([doOwnsValues]);
  FEvents := TQueue<TJ2MEMediaEvent>.Create;
  FTones := TList<TJ2METone>.Create;
end;

destructor TJ2MEMedia.Destroy;
begin
  FTones.Free;
  FEvents.Free;
  FPlayers.Free;
  inherited;
end;

procedure TJ2MEMedia.Install;
var
  B: TJavaClassBuilder;

  procedure Done;
  begin
    FVM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure Native(const Name, Desc: string; Flags: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := Flags or JVM_ACC_NATIVE;
  end;

  procedure AbstractMethod(const Name, Desc: string);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  end;

  procedure IntConstant(const Name: string; Value: Integer);
  begin
    B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

  procedure StringConstant(const Name, Value: string);
  begin
    B.Field(Name, 'Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Ref(FVM.InternString(Value));
  end;

  procedure PlayerMethods(abstract: Boolean);

    procedure Add(const Name, Desc: string);
    begin
      if abstract then
        AbstractMethod(Name, Desc)
      else
        Native(Name, Desc);
    end;

  begin
    for var Name in ['deallocate', 'close', 'stop'] do
      Add(Name, '()V');
    Add('getState', '()I');
    Add('getMediaTime', '()J');
    Add('getDuration', '()J');
    Add('getContentType', '()Ljava/lang/String;');
    Add('setMediaTime', '(J)J');
    Add('setLoopCount', '(I)V');
    for var Name in ['addPlayerListener', 'removePlayerListener'] do
      Add(Name, '(Ljavax/microedition/media/PlayerListener;)V');
    Add('getControl', '(Ljava/lang/String;)Ljavax/microedition/media/Control;');
    Add('getControls', '()[Ljavax/microedition/media/Control;');
    Add('setTimeBase', '(Ljavax/microedition/media/TimeBase;)V');
    Add('getTimeBase', '()Ljavax/microedition/media/TimeBase;');
    if abstract then
      for var Name in ['realize', 'prefetch', 'start'] do
        Add(Name, '()V');
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(Media + 'MediaException', 'java/lang/Exception');
    Native('<init>', '()V');
    Native('<init>', '(Ljava/lang/String;)V');
    Done;
    B := TJavaClassBuilder.Create(Control, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    Done;
    B := TJavaClassBuilder.Create(Controllable, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    AbstractMethod('getControl', '(Ljava/lang/String;)Ljavax/microedition/media/Control;');
    AbstractMethod('getControls', '()[Ljavax/microedition/media/Control;');
    Done;
    B := TJavaClassBuilder.Create(PlayerAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [Controllable];
    IntConstant('CLOSED', 0);
    IntConstant('UNREALIZED', 100);
    IntConstant('REALIZED', 200);
    IntConstant('PREFETCHED', 300);
    IntConstant('STARTED', 400);
    B.Field('TIME_UNKNOWN', 'J', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Long(-1);
    PlayerMethods(True);
    Done;
    B := TJavaClassBuilder.Create(VolumeAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [Control];
    AbstractMethod('setLevel', '(I)I');
    AbstractMethod('getLevel', '()I');
    AbstractMethod('setMute', '(Z)V');
    AbstractMethod('isMuted', '()Z');
    Done;
    B := TJavaClassBuilder.Create(Listener, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    for var Name in ['STARTED', 'STOPPED', 'CLOSED', 'ERROR', 'DURATION_UPDATED', 'END_OF_MEDIA', 'VOLUME_CHANGED', 'DEVICE_AVAILABLE', 'DEVICE_UNAVAILABLE'] do
    begin
      var Value := LowerCase(Name).Replace('_', '');
      if Name = 'DURATION_UPDATED' then
        Value := 'durationUpdated'
      else if Name = 'END_OF_MEDIA' then
        Value := 'endOfMedia'
      else if Name = 'VOLUME_CHANGED' then
        Value := 'volumeChanged'
      else if Name = 'DEVICE_AVAILABLE' then
        Value := 'deviceAvailable'
      else if Name = 'DEVICE_UNAVAILABLE' then
        Value := 'deviceUnavailable';
      StringConstant(Name, Value);
    end;
    AbstractMethod('playerUpdate', '(' + PlayerDesc + 'Ljava/lang/String;Ljava/lang/Object;)V');
    Done;
    B := TJavaClassBuilder.Create(TimeBase, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    AbstractMethod('getTime', '()J');
    Done;
    B := TJavaClassBuilder.Create(TimeBaseImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [TimeBase];
    Native('getTime', '()J');
    Done;
    FTimeBase := FVM.NewObject(TimeBaseImpl);
    FVM.AddRoot(FTimeBase);
    B := TJavaClassBuilder.Create(VolumeImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [VolumeAPI];
    B.Field('$player', PlayerDesc, JVM_ACC_PRIVATE);
    for var Name in ['getLevel', 'isMuted'] do
    begin
      var D := '()I';
      if Name = 'isMuted' then
        D := '()Z';
      Native(Name, D);
    end;
    Native('setLevel', '(I)I');
    Native('setMute', '(Z)V');
    Done;
    B := TJavaClassBuilder.Create(PlayerImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [PlayerAPI];
    B.Field('$volume', VolumeDesc, JVM_ACC_PRIVATE);
    B.Field('$listeners', '[Ljavax/microedition/media/PlayerListener;', JVM_ACC_PRIVATE);
    PlayerMethods(False);
    Native('$beginRealize', '()I', JVM_ACC_PRIVATE);
    Native('$realizeStep', '(I)Z', JVM_ACC_PRIVATE);
    Native('$prefetch', '()V', JVM_ACC_PRIVATE);
    Native('$start', '()V', JVM_ACC_PRIVATE);
    // Parsing/rendering a MIDI is split into bounded native decode blocks. The
    // surrounding guest loop preserves budgets, stop, cancellation and GC.
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(PlayerImpl, '$beginRealize', '()I'));
    B.Emit([$3C]);
    B.Mark('loop');
    B.Emit([$2A, $1B]);
    B.Ref($B7, B.Member(PlayerImpl, '$realizeStep', '(I)Z'));
    B.Jump($9A, 'done');
    B.Ref($B8, B.Member('java/lang/Thread', 'yield', '()V'));
    B.Jump($A7, 'loop');
    B.Mark('done');
    B.Emit([$B1]);
    B.Finish('realize', '()V', JVM_ACC_PUBLIC, 2, 2);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B6, B.Member(PlayerImpl, 'realize', '()V'));
    B.Emit([$2A]);
    B.Ref($B7, B.Member(PlayerImpl, '$prefetch', '()V'));
    B.Emit([$B1]);
    B.Finish('prefetch', '()V', JVM_ACC_PUBLIC, 1, 1);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B6, B.Member(PlayerImpl, 'prefetch', '()V'));
    B.Emit([$2A]);
    B.Ref($B7, B.Member(PlayerImpl, '$start', '()V'));
    B.Emit([$B1]);
    B.Finish('start', '()V', JVM_ACC_PUBLIC, 1, 1);
    Done;
    B := TJavaClassBuilder.Create(Manager, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    StringConstant('TONE_DEVICE_LOCATOR', 'device://tone');
    Native('getSupportedContentTypes', '(Ljava/lang/String;)[Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('getSupportedProtocols', '(Ljava/lang/String;)[Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('createPlayer', '(Ljava/lang/String;)' + PlayerDesc, JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('$create', '([BLjava/lang/String;)' + PlayerDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    Native('$stream', '(Ljava/io/InputStream;)V', JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    Native('playTone', '(III)V', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('getSystemTimeBase', '()Ljavax/microedition/media/TimeBase;', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    // InputStream reads stay virtual, including custom guest streams/yields.
    B.Start;
    B.Emit([$2A]);
    B.Ref($B8, B.Member(Manager, '$stream', '(Ljava/io/InputStream;)V'));
    B.Ref($BB, B.ClassRef('java/io/ByteArrayOutputStream'));
    B.Emit([$59]);
    B.Ref($B7, B.Member('java/io/ByteArrayOutputStream', '<init>', '()V'));
    B.Emit([$4D]);
    B.Emit([$11, 1, 0, $BC, 8, $4E]);
    B.Mark('loop');
    B.Emit([$2A, $2D]);
    B.Ref($B6, B.Member('java/io/InputStream', 'read', '([B)I'));
    B.Emit([$36, 4, $15, 4]);
    B.Jump($9B, 'end');
    B.Emit([$15, 4]);
    B.Jump($99, 'one');
    B.Emit([$2C, $2D, $03, $15, 4]);
    B.Ref($B6, B.Member('java/io/ByteArrayOutputStream', 'write', '([BII)V'));
    B.Jump($A7, 'loop');
    B.Mark('one');
    B.Emit([$2A]);
    B.Ref($B6, B.Member('java/io/InputStream', 'read', '()I'));
    B.Emit([$36, 4, $15, 4]);
    B.Jump($9B, 'end');
    B.Emit([$2C, $15, 4]);
    B.Ref($B6, B.Member('java/io/ByteArrayOutputStream', 'write', '(I)V'));
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$2C]);
    B.Ref($B6, B.Member('java/io/ByteArrayOutputStream', 'toByteArray', '()[B'));
    B.Emit([$2B]);
    B.Ref($B8, B.Member(Manager, '$create', '([BLjava/lang/String;)' + PlayerDesc));
    B.Emit([$B0]);
    B.Finish('createPlayer', '(Ljava/io/InputStream;Ljava/lang/String;)' + PlayerDesc, JVM_ACC_PUBLIC or JVM_ACC_STATIC, 4, 5);
    Done;
  finally
    B.Free;
  end;
end;

function TJ2MEMedia.Handles(const Owner: string): Boolean;
begin
  Result := (Owner = Manager) or (Owner = PlayerImpl) or (Owner = VolumeImpl) or (Owner = TimeBaseImpl);
end;

function TJ2MEMedia.Player(Ref: Integer; AllowClosed: Boolean): TJ2MEMediaPlayer;
begin
  FVM.GetObject(Ref);
  if not FPlayers.TryGetValue(Ref, Result) then
    raise EJVMError.Create('Unknown media player');
  if not AllowClosed and (Result.State = 0) then
    FVM.RaiseJava('java/lang/IllegalStateException', 'Player is closed');
end;

procedure TJ2MEMedia.Sweep;
begin
  if FSeenGC = FVM.GCGeneration then
    Exit;
  FSeenGC := FVM.GCGeneration;
  for var Ref in FPlayers.Keys.ToArray do
    if not FVM.IsObjectAlive(Ref) then
      FPlayers.Remove(Ref);
end;

function TJ2MEMedia.CreatePlayer(const Data: TBytes; const ContentType: string): Integer;
var
  P: TJ2MEMediaPlayer;
  Name: string;
  Ref, Live: Integer;
  Bytes: Int64;
begin
  Sweep;
  Live := 0;
  Bytes := Length(Data);
  for P in FPlayers.Values do
  begin
    if P.State <> 0 then
      Inc(Live);
    Inc(Bytes, Length(P.Data));
  end;
  if Live >= 128 then
    FVM.RaiseJava(Media + 'MediaException', 'Live player limit');
  if (Length(Data) > 16 * 1024 * 1024) or (Bytes > 64 * 1024 * 1024) then
    FVM.RaiseJava(Media + 'MediaException', 'Encoded media memory limit');
  Name := ContentType;
  var Separator := Pos(';', Name);
  if Separator > 0 then
    SetLength(Name, Separator - 1);
  Name := LowerCase(Trim(Name));
  if Name = '' then
  begin
    if (Length(Data) >= 12) and (TEncoding.ASCII.GetString(Data, 0, 4) = 'RIFF') and (TEncoding.ASCII.GetString(Data, 8, 4) = 'WAVE') then
      Name := 'audio/x-wav'
    else if (Length(Data) >= 4) and (TEncoding.ASCII.GetString(Data, 0, 4) = 'MThd') then
      Name := 'audio/midi';
  end;
  if (Name = 'audio/wav') or (Name = 'audio/wave') then
    Name := 'audio/x-wav';
  if (Name = 'audio/x-midi') or (Name = 'audio/sp-midi') then
    Name := 'audio/midi';
  if (Name <> 'audio/x-wav') and (Name <> 'audio/midi') then
    FVM.RaiseJava(Media + 'MediaException', 'Unsupported content type: ' + Name);
  P := TJ2MEMediaPlayer.Create;
  try
    P.ContentType := Name;
    P.Data := Copy(Data);
    P.State := 100;
    P.Volume := 100;
    P.LoopCount := 1;
    P.LoopsLeft := 1;
    P.Reference := FVM.NewObject(PlayerImpl);
    Result := P.Reference;
    Ref := FVM.NewObject(VolumeImpl);
    FVM.GetObject(Ref).Fields[VolumeImpl + '.$player:' + PlayerDesc] := TJVMValue.Ref(Result);
    FVM.GetObject(Result).Fields[PlayerImpl + '.$volume:' + VolumeDesc] := TJVMValue.Ref(Ref);
    FPlayers.Add(Result, P);
    P := nil;
  finally
    P.Free;
  end;
end;

function TJ2MEMedia.RealizeStep(P: TJ2MEMediaPlayer; Generation: Integer): Boolean;
var
  Samples: TArray<SmallInt>;
  Read, Needed, Capacity, Total: Integer;
begin
  Result := True;
  if (P.Generation <> Generation) or (P.State <> 100) or not P.Decoding then
    Exit;
  try
    if P.Decoder = nil then
    begin
      if P.ContentType = 'audio/midi' then
        P.Decoder := OpenMidi(P.Data)
      else
        P.Decoder := OpenWav(P.Data);
      P.Info := GetAudioInfo(P.Decoder);
      if (P.Info.SampleRate < 1) or (P.Info.SampleRate > 384000) or not (P.Info.Channels in [1, 2]) then
        raise EArgumentException.Create('Unsupported PCM format');
      // Finite long resources are decoded on demand rather than expanded in
      // full during realize. Short clips retain the existing PCM path.
      if Length(P.Info.TrackDurations) > 0 then
      begin
        var Seconds := P.Info.TrackDurations[0];
        if not IsNan(Seconds) and not IsInfinite(Seconds) and (Seconds >= 0) and (Seconds <= 86402) then
        begin
          var Frames := Round(Seconds * P.Info.SampleRate);
          if Frames > MaxClipSamples div P.Info.Channels then
          begin
            P.Streaming := True;
            P.FrameCount := Frames;
            P.Decoding := False;
            P.State := 200;
            TimeEvent(P, 'durationUpdated', P.Duration);
            Exit;
          end;
        end;
      end;
    end;
    SetLength(FDecodeBuffer, 4096 * P.Info.Channels);
    Samples := FDecodeBuffer;
    Read := P.Decoder.Render(Samples, 4096);
    if (Read < 0) or (Read > 4096) then
      raise EArgumentException.Create('Invalid decoder result');
    Needed := P.SampleCount + Read * P.Info.Channels;
    if Needed > MaxClipSamples then
      raise EArgumentException.Create('Decoded clip limit');
    if Needed > Length(P.PCM) then
    begin
      Capacity := Min(MaxClipSamples, Max(Needed, Max(8192, Length(P.PCM) * 2)));
      Total := Capacity;
      for var Other in FPlayers.Values do
        if Other <> P then
          Inc(Total, Length(Other.PCM));
      if Total > MaxTotalSamples then
        raise EArgumentException.Create('Decoded media memory limit');
      SetLength(P.PCM, Capacity);
    end;
    if Read > 0 then
      Move(Samples[0], P.PCM[P.SampleCount], Read * P.Info.Channels * SizeOf(SmallInt));
    P.SampleCount := Needed;
    if Read = 0 then
    begin
      P.FrameCount := Needed div P.Info.Channels;
      SetLength(P.PCM, Needed);
      P.Decoder := nil;
      P.Decoding := False;
      P.State := 200;
      TimeEvent(P, 'durationUpdated', P.Duration);
    end
    else
    begin
      Result := False;
      FVM.YieldToHost;
    end;
  except
    on E: EJVMThrown do
      raise;
    on E: Exception do
    begin
      P.DiscardDecodedAudio;
      FVM.RaiseJava(Media + 'MediaException', E.Message);
    end;
  end;
end;

procedure TJ2MEMedia.ReadStream(P: TJ2MEMediaPlayer; Source, Next: Int64);
begin
  if (Source >= P.CacheFrame) and (Next < P.CacheFrame + P.SampleCount div P.Info.Channels) then
    Exit;
  var Prefix := 0;
  var Tail: array[0..1] of SmallInt;
  if (P.SampleCount > 0) and (Source = P.CacheFrame + P.SampleCount div P.Info.Channels - 1) then
  begin
    Prefix := 1;
    for var C := 0 to P.Info.Channels - 1 do
      Tail[C] := P.PCM[P.SampleCount - P.Info.Channels + C];
  end;
  var Start := Source + Prefix;
  var Samples: TArray<SmallInt>;
  SetLength(FDecodeBuffer, 4096 * P.Info.Channels);
  Samples := FDecodeBuffer;
  var Seeker: IAudioSeekSource;
  if (P.Decoder = nil) or ((P.DecoderFrame > Start) and not Supports(P.Decoder, IAudioSeekSource, Seeker)) then
  begin
    if P.ContentType = 'audio/midi' then
      P.Decoder := OpenMidi(P.Data)
    else
      P.Decoder := OpenWav(P.Data);
    P.DecoderFrame := 0;
    var Info := GetAudioInfo(P.Decoder);
    if (Info.SampleRate <> P.Info.SampleRate) or (Info.Channels <> P.Info.Channels) then
      raise EJVMError.Create('Incompatible streaming audio format');
  end;
  if (P.DecoderFrame <> Start) and Supports(P.Decoder, IAudioSeekSource, Seeker) then
  begin
    P.DecoderFrame := Seeker.SeekFrame(Start,
      function: Boolean
      begin
        Result := FVM.StopRequested or TThread.CheckTerminated;
      end);
    if P.DecoderFrame <> Start then
      raise EJVMError.Create('Invalid streaming audio seek');
  end;
  while P.DecoderFrame < Start do
  begin
    if FVM.StopRequested or TThread.CheckTerminated then
      raise EAbort.Create('Media seek cancelled');
    var Count := Integer(Min(Int64(4096), Start - P.DecoderFrame));
    var Read := P.Decoder.Render(Samples, Count);
    if (Read <= 0) or (Read > Count) then
      raise EJVMError.Create('Invalid streaming audio seek');
    Inc(P.DecoderFrame, Read);
  end;
  if FVM.StopRequested or TThread.CheckTerminated then
    raise EAbort.Create('Media render cancelled');
  var Count := Integer(Min(Int64(4096), P.FrameCount - Start));
  var Read := P.Decoder.Render(Samples, Count);
  if (Read < 0) or (Read > Count) or (Source + Prefix + Read <= Next) then
    raise EJVMError.Create('Invalid streaming audio block');
  Inc(P.DecoderFrame, Read);
  P.CacheFrame := Source;
  P.SampleCount := (Prefix + Read) * P.Info.Channels;
  SetLength(P.PCM, P.SampleCount);
  if Prefix <> 0 then
    for var C := 0 to P.Info.Channels - 1 do
      P.PCM[C] := Tail[C];
  if Read <> 0 then
    Move(Samples[0], P.PCM[Prefix * P.Info.Channels], Read * P.Info.Channels * SizeOf(SmallInt));
end;

procedure TJ2MEMedia.PostEvent(P: TJ2MEMediaPlayer; const Name: string; Data: Integer);
var
  Value: TJVMValue;
  E: TJ2MEMediaEvent;
begin
  if not FVM.GetObject(P.Reference).Fields.TryGetValue(PlayerImpl + '.$listeners:[Ljavax/microedition/media/PlayerListener;', Value) or (Value.AsRef = 0) then
    Exit;
  for var Target in FVM.GetObject(Value.AsRef).Elements do
  begin
    if FEvents.Count >= 65536 then
      raise EJVMError.Create('Media event queue limit');
    E.Listener := Target.AsRef;
    E.Player := P.Reference;
    E.EventName := FVM.InternString(Name);
    E.Data := Data;
    FVM.AddRoot(E.Listener);
    FVM.AddRoot(E.Player);
    FVM.AddRoot(E.EventName);
    FVM.AddRoot(E.Data);
    FEvents.Enqueue(E);
  end;
end;

procedure TJ2MEMedia.TimeEvent(P: TJ2MEMediaPlayer; const Name: string; Time: Int64);
var
  Value: TJVMValue;
begin
  Value := FVM.GetObject(P.Reference).Fields[PlayerImpl + '.$listeners:[Ljavax/microedition/media/PlayerListener;'];
  if (Value.AsRef <> 0) and (Length(FVM.GetObject(Value.AsRef).Elements) <> 0) then
    PostEvent(P, Name, NewJavaLong(FVM, Time));
end;

procedure TJ2MEMedia.SetStarted(P: TJ2MEMediaPlayer; Started: Boolean);
begin
  if Started = P.Rooted then
    Exit;
  P.Rooted := Started;
  if Started then
    FVM.AddRoot(P.Reference)
  else
    FVM.RemoveRoot(P.Reference);
end;

procedure TJ2MEMedia.EndOfMedia(P: TJ2MEMediaPlayer);
begin
  TimeEvent(P, 'endOfMedia', P.Duration);
  if (P.FrameCount > 0) and ((P.LoopsLeft = -1) or (P.LoopsLeft > 1)) then
  begin
    if P.LoopsLeft > 1 then
      Dec(P.LoopsLeft);
    P.Position := 0;
    TimeEvent(P, 'started', 0);
  end
  else
  begin
    P.State := 300;
    P.LoopsLeft := 0;
    SetStarted(P, False);
  end;
end;

function TJ2MEMedia.TakeEvent(out Event: TJ2MEMediaEvent): Boolean;
begin
  Result := FEvents.Count <> 0;
  if Result then
    Event := FEvents.Dequeue;
end;

procedure TJ2MEMedia.ReleaseEvent(const Event: TJ2MEMediaEvent);
begin
  FVM.RemoveRoot(Event.Listener);
  FVM.RemoveRoot(Event.Player);
  FVM.RemoveRoot(Event.EventName);
  FVM.RemoveRoot(Event.Data);
end;

procedure TJ2MEMedia.ClearEvents;
begin
  while FEvents.Count <> 0 do
    ReleaseEvent(FEvents.Dequeue);
end;

procedure TJ2MEMedia.Shutdown;
begin
  ClearEvents;
  FTones.Clear;
  for var P in FPlayers.Values do
  begin
    SetStarted(P, False);
    P.State := 0;
    P.DiscardDecodedAudio;
    P.Data := nil;
    Inc(P.Generation);
  end;
end;

function TJ2MEMedia.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  N, C, Name: string;
  P: TJ2MEMediaPlayer;
  Ref, ArrayRef, V, Index: Integer;
  A: TJVMObject;
  Data: TBytes;
  Value: TJVMValue;

  function Strings(const Values: array of string): TJVMValue;
  begin
    var R := FVM.NewArray('[Ljava/lang/String;', Length(Values));
    for var I := 0 to High(Values) do
      FVM.GetObject(R).ElementValues[I] := TJVMValue.Ref(FVM.InternString(Values[I]));
    Result := TJVMValue.Ref(R);
  end;

begin
  N := Method.Name;
  C := Method.Owner.Name;
  Result := Default(TJVMValue);
  if C = TimeBaseImpl then
    Exit(TJVMValue.Long(FClockFrames * 1000000 div 44100));
  if C = Manager then
  begin
    if N = '$stream' then
    begin
      if Args[0].AsRef = 0 then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Null media stream');
      Exit;
    end;
    if N = '$create' then
    begin
      A := FVM.GetObject(Args[0].AsRef);
      SetLength(Data, A.ElementCount);
      for var I := 0 to High(Data) do
        Data[I] := Byte(A.ElementValues[I].AsInt);
      Name := '';
      if Args[1].AsRef <> 0 then
        Name := FVM.GetObject(Args[1].AsRef).Text;
      Exit(TJVMValue.Ref(CreatePlayer(Data, Name)));
    end;
    if N = 'createPlayer' then
    begin
      if Args[0].AsRef = 0 then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Null media locator');
      Name := FVM.GetObject(Args[0].AsRef).Text;
      if LowerCase(Name).StartsWith('resource:') then
      begin
        var Path := Copy(Name, 10, MaxInt);
        while Path.StartsWith('//') do
          Delete(Path, 1, 1);
        if not TJavaHost(FVM.Host).LoadResource(Path, Data) then
          FVM.RaiseJava('java/io/IOException', 'Media resource not found: ' + Path);
        Exit(TJVMValue.Ref(CreatePlayer(Data, '')));
      end;
      FVM.RaiseJava(Media + 'MediaException', 'Unsupported media locator: ' + Name);
    end;
    if N = 'getSupportedContentTypes' then
    begin
      if (Args[0].AsRef <> 0) and (FVM.GetObject(Args[0].AsRef).Text <> 'resource') then
        Exit(Strings([]));
      Exit(Strings(['audio/x-wav', 'audio/midi']));
    end;
    if N = 'getSupportedProtocols' then
    begin
      if Args[0].AsRef <> 0 then
      begin
        Name := LowerCase(FVM.GetObject(Args[0].AsRef).Text);
        if (Name <> 'audio/x-wav') and (Name <> 'audio/midi') then
          Exit(Strings([]));
      end;
      Exit(Strings(['resource']));
    end;
    if N = 'getSystemTimeBase' then
      Exit(TJVMValue.Ref(FTimeBase));
    if N = 'playTone' then
    begin
      if (Args[0].AsInt < 0) or (Args[0].AsInt > 127) or (Args[1].AsInt <= 0) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Tone note/duration');
      if FTones.Count >= 64 then
        FVM.RaiseJava(Media + 'MediaException', 'Tone voice limit');
      var T: TJ2METone;
      T.Remaining := Int64(Args[1].AsInt) * 44100 div 1000;
      T.Phase := 0;
      T.Increment := 2 * Pi * (440 * Power(2, (Args[0].AsInt - 69) / 12)) / 44100;
      T.Volume := EnsureRange(Args[2].AsInt, 0, 100);
      FTones.Add(T);
      Exit;
    end;
  end;
  Ref := Args[0].AsRef;
  if C = VolumeImpl then
    Ref := FVM.GetObject(Ref).Fields[VolumeImpl + '.$player:' + PlayerDesc].AsRef;
  P := Player(Ref, (N = 'getState') or (N = 'close'));
  if C = VolumeImpl then
  begin
    if N = 'getLevel' then
      Exit(TJVMValue.Int(P.Volume));
    if N = 'isMuted' then
      Exit(TJVMValue.Int(Ord(P.Muted)));
    if N = 'setLevel' then
    begin
      V := EnsureRange(Args[1].AsInt, 0, 100);
      if V <> P.Volume then
      begin
        P.Volume := V;
        PostEvent(P, 'volumeChanged', Args[0].AsRef);
      end;
      Exit(TJVMValue.Int(V));
    end;
    if N = 'setMute' then
    begin
      var Muted := Args[1].AsInt <> 0;
      if P.Muted <> Muted then
      begin
        P.Muted := Muted;
        PostEvent(P, 'volumeChanged', Args[0].AsRef);
      end;
      Exit;
    end;
  end;
  if N = 'getState' then
    Exit(TJVMValue.Int(P.State));
  if N = 'getMediaTime' then
    Exit(TJVMValue.Long(P.MediaTime));
  if N = 'getDuration' then
    Exit(TJVMValue.Long(P.Duration));
  if N = '$beginRealize' then
  begin
    if (P.State = 100) and not P.Decoding then
    begin
      Inc(P.Generation);
      P.Decoding := True;
    end;
    Exit(TJVMValue.Int(P.Generation));
  end;
  if N = '$realizeStep' then
    Exit(TJVMValue.Int(Ord(RealizeStep(P, Args[1].AsInt))));
  if N = '$prefetch' then
  begin
    if P.State = 200 then
      P.State := 300;
    Exit;
  end;
  if N = '$start' then
  begin
    if P.State = 400 then
      Exit;
    if P.State <> 300 then
      FVM.RaiseJava(Media + 'MediaException', 'Player was not prefetched');
    if P.Position >= Int64(P.FrameCount) * 44100 then
    begin
      P.Position := 0;
      P.LoopsLeft := P.LoopCount;
    end;
    P.State := 400;
    SetStarted(P, True);
    TimeEvent(P, 'started', P.MediaTime);
    if P.FrameCount = 0 then
      EndOfMedia(P);
    Exit;
  end;
  if (N = 'stop') or (N = 'deallocate') or (N = 'close') then
  begin
    if (N = 'close') and (P.State = 0) then
      Exit;
    if P.State = 400 then
    begin
      P.State := 300;
      SetStarted(P, False);
      if N <> 'close' then
        TimeEvent(P, 'stopped', P.MediaTime);
    end;
    if N = 'deallocate' then
    begin
      if P.Decoding then
      begin
        Inc(P.Generation);
        P.DiscardDecodedAudio;
      end;
      if P.State >= 300 then
        P.State := 200;
      if P.Streaming then
      begin
        P.Decoder := nil;
        P.PCM := nil;
        P.SampleCount := 0;
        P.CacheFrame := 0;
        P.DecoderFrame := 0;
      end;
    end;
    if N = 'close' then
    begin
      Inc(P.Generation);
      P.State := 0;
      P.DiscardDecodedAudio;
      P.Data := nil;
      PostEvent(P, 'closed', 0);
      FVM.GetObject(Ref).Fields[PlayerImpl + '.$listeners:[Ljavax/microedition/media/PlayerListener;'] := TJVMValue.Ref(0);
    end;
    Exit;
  end;
  if N = 'setLoopCount' then
  begin
    V := Args[1].AsInt;
    if P.State = 400 then
      FVM.RaiseJava('java/lang/IllegalStateException', 'Started player');
    if (V = 0) or (V < -1) then
      FVM.RaiseJava('java/lang/IllegalArgumentException');
    P.LoopCount := V;
    P.LoopsLeft := V;
    Exit;
  end;
  if (N = 'getContentType') or (N = 'getControls') or (N = 'getControl') or (N = 'setMediaTime') then
    if P.State = 100 then
      FVM.RaiseJava('java/lang/IllegalStateException', 'Unrealized player');
  if N = 'getContentType' then
    Exit(TJVMValue.Ref(FVM.NewString(P.ContentType)));
  if N = 'setMediaTime' then
  begin
    var Time := EnsureRange(Args[1].AsLong, Int64(0), P.Duration);
    P.Position := (Time * P.Info.SampleRate div 1000000) * 44100;
    if Time = P.Duration then
      P.Position := Int64(P.FrameCount) * 44100;
    Exit(TJVMValue.Long(P.MediaTime));
  end;
  if N = 'getControl' then
  begin
    if Args[1].AsRef = 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Null control type');
    Name := FVM.GetObject(Args[1].AsRef).Text;
    if (Name = 'VolumeControl') or (Name = 'javax.microedition.media.control.VolumeControl') then
      Exit(FVM.GetObject(Ref).Fields[PlayerImpl + '.$volume:' + VolumeDesc]);
    Exit(TJVMValue.Ref(0));
  end;
  if N = 'getControls' then
  begin
    ArrayRef := FVM.NewArray('[Ljavax/microedition/media/Control;', 1);
    FVM.GetObject(ArrayRef).ElementValues[0] := FVM.GetObject(Ref).Fields[PlayerImpl + '.$volume:' + VolumeDesc];
    Exit(TJVMValue.Ref(ArrayRef));
  end;
  if N = 'getTimeBase' then
    Exit(TJVMValue.Ref(FTimeBase));
  if N = 'setTimeBase' then
  begin
    if P.State < 300 then
      FVM.RaiseJava('java/lang/IllegalStateException', 'Player not prefetched');
    if (Args[1].AsRef <> 0) and (Args[1].AsRef <> FTimeBase) then
      FVM.RaiseJava(Media + 'MediaException', 'Custom time bases are not implemented');
    Exit;
  end;
  if (N = 'addPlayerListener') or (N = 'removePlayerListener') then
  begin
    Ref := Args[1].AsRef;
    if Ref = 0 then
      Exit;
    A := nil;
    Index := -1;
    Value := FVM.GetObject(P.Reference).Fields[PlayerImpl + '.$listeners:[Ljavax/microedition/media/PlayerListener;'];
    V := 0;
    if Value.AsRef <> 0 then
    begin
      A := FVM.GetObject(Value.AsRef);
      V := A.ElementCount;
      for var I := 0 to V - 1 do
        if A.ElementValues[I].AsRef = Ref then
          Index := I;
    end;
    if ((N = 'addPlayerListener') and (Index >= 0)) or ((N = 'removePlayerListener') and (Index < 0)) then
      Exit;
    var Adding := N = 'addPlayerListener';
    if Adding and (V >= 64) then
      FVM.RaiseJava(Media + 'MediaException', 'Listener limit');
    ArrayRef := FVM.NewArray('[Ljavax/microedition/media/PlayerListener;', V + IfThen(Adding, 1, -1));
    var J := 0;
    for var I := 0 to V - 1 do
      if Adding or (I <> Index) then
      begin
        FVM.GetObject(ArrayRef).ElementValues[J] := A.ElementValues[I];
        Inc(J);
      end;
    if Adding then
      FVM.GetObject(ArrayRef).ElementValues[J] := TJVMValue.Ref(Ref);
    FVM.GetObject(P.Reference).Fields[PlayerImpl + '.$listeners:[Ljavax/microedition/media/PlayerListener;'] := TJVMValue.Ref(ArrayRef);
    Exit;
  end;
  raise EJVMUnsupported.Create('Unimplemented media native ' + C + '.' + N);
end;

procedure TJ2MEMedia.RenderMixInto(var Mix: TArray<Int64>; Frames: Integer);
begin
  if (Frames < 0) or (Frames > 8192) then
    raise EArgumentOutOfRangeException.Create('Media render block');
  Sweep;
  SetLength(Mix, Frames * 2);
  if Length(Mix) <> 0 then
    FillChar(Mix[0], Length(Mix) * SizeOf(Int64), 0);
  for var P in FPlayers.Values do
    if P.State = 400 then
    begin
      for var I := 0 to Frames - 1 do
      begin
        if P.State <> 400 then
          Break;
        if (P.FrameCount = 0) or (P.Position >= P.FrameCount * 44100) then
        begin
          EndOfMedia(P);
          if P.State <> 400 then
            Break;
        end;
        var Source := P.Position div 44100;
        var Fraction := P.Position mod 44100;
        var Next := Min(Source + 1, P.FrameCount - 1);
        if P.Streaming then
          ReadStream(P, Source, Next);
        var Offset := Int64(0);
        if P.Streaming then
          Offset := P.CacheFrame;
        for var C := 0 to 1 do
          if not P.Muted then
          begin
            var Channel := Min(C, P.Info.Channels - 1);
            var A := P.PCM[(Source - Offset) * P.Info.Channels + Channel];
            var B := P.PCM[(Next - Offset) * P.Info.Channels + Channel];
            var Sample := (Int64(A) * (44100 - Fraction) + Int64(B) * Fraction) div 44100;
            Inc(Mix[I * 2 + C], Sample * P.Volume div 100);
          end;
        Inc(P.Position, P.Info.SampleRate);
        if P.Position >= Int64(P.FrameCount) * 44100 then
        begin
          P.Position := Int64(P.FrameCount) * 44100;
          EndOfMedia(P);
        end;
      end;
    end;
  for var T := FTones.Count - 1 downto 0 do
  begin
    var Tone := FTones[T];
    for var I := 0 to Frames - 1 do
    begin
      if Tone.Remaining <= 0 then
        Break;
      var Sample := Round(Sin(Tone.Phase) * 16384 * Tone.Volume / 100);
      Inc(Mix[I * 2], Sample);
      Inc(Mix[I * 2 + 1], Sample);
      Tone.Phase := Tone.Phase + Tone.Increment;
      if Tone.Phase > 2 * Pi then
        Tone.Phase := Tone.Phase - 2 * Pi;
      Dec(Tone.Remaining);
    end;
    if Tone.Remaining <= 0 then
      FTones.Delete(T)
    else
      FTones[T] := Tone;
  end;
  Inc(FClockFrames, Frames);
end;

function TJ2MEMedia.RenderMix(Frames: Integer): TArray<Int64>;
begin
  RenderMixInto(Result, Frames);
end;

function TJ2MEMedia.Render(Frames: Integer): TArray<SmallInt>;
begin
  var Mix := RenderMix(Frames);
  SetLength(Result, Length(Mix));
  for var I := 0 to High(Result) do
    Result[I] := SmallInt(EnsureRange(Mix[I], Int64(-32768), Int64(32767)));
end;

procedure TJ2MEMedia.TransferState(S: TJVMStateIO);
begin
  var Tag := 'J2ME.Media-1';
  if not S.Loading then
    for var P in FPlayers.Values do
      if P.Streaming then
      begin
        Tag := 'J2ME.Media-2';
        Break;
      end;
  S.Text(Tag);
  if (Tag <> 'J2ME.Media-1') and (Tag <> 'J2ME.Media-2') then
    raise EReadError.Create('Unsupported media snapshot version');
  var Version2 := Tag = 'J2ME.Media-2';
  S.Int64Value(FClockFrames);
  S.Int(FTimeBase);
  var Keys := FPlayers.Keys.ToArray;
  var N: Integer := Length(Keys);
  S.Count(N, 256);
  if S.Loading then
    FPlayers.Clear
  else
    TArray.Sort<Integer>(Keys);
  for var I := 0 to N - 1 do
  begin
    var Key := 0;
    var P: TJ2MEMediaPlayer;
    if S.Loading then
      P := TJ2MEMediaPlayer.Create
    else
    begin
      Key := Keys[I];
      P := FPlayers[Key];
    end;
    try
      S.Int(Key);
      S.Int(P.Reference);
      S.Int(P.State);
      S.Int(P.Volume);
      S.Int(P.LoopCount);
      S.Int(P.LoopsLeft);
      S.Int(P.Generation);
      S.Int(P.SampleCount);
      if Version2 then
        S.Int64Value(P.FrameCount)
      else
      begin
        var Frames := Integer(P.FrameCount);
        S.Int(Frames);
        if S.Loading then
          P.FrameCount := Frames;
      end;
      S.Int(P.Info.SampleRate);
      S.Int(P.Info.Channels);
      S.Bool(P.Muted);
      S.Bool(P.Decoding);
      S.Bool(P.Rooted);
      S.Text(P.ContentType);
      S.Bytes(P.Data);
      S.PCM(P.PCM);
      S.Int64Value(P.Position);
      if Version2 then
      begin
        S.Bool(P.Streaming);
        if P.Streaming then
          S.Int64Value(P.CacheFrame);
      end;
      if P.Streaming then
      begin
        if not (P.Info.Channels in [1, 2]) or (P.Info.SampleRate < 1) or (P.Info.SampleRate > 384000) or
          P.Decoding or ((P.State <> 200) and (P.State <> 300) and (P.State <> 400)) or (P.FrameCount <= 0) or
          (P.FrameCount > Int64(P.Info.SampleRate) * 86402) or
          (P.SampleCount < 0) or (P.SampleCount mod P.Info.Channels <> 0) or
          (Length(P.PCM) > 4097 * P.Info.Channels) or (P.CacheFrame < 0) or (P.CacheFrame > P.FrameCount) or
          (P.CacheFrame + P.SampleCount div P.Info.Channels > P.FrameCount) or
          (P.Position < 0) or (P.Position > P.FrameCount * 44100) then
          raise EReadError.Create('Invalid snapshot streaming audio');
      end;
      if (P.SampleCount < 0) or (P.FrameCount < 0) then
        raise EReadError.Create('Invalid snapshot media PCM');
      // Version 1 originally retained counters after close had freed the PCM.
      // Accept that old closed-player representation without weakening checks
      // for live/decoding players or changing the on-disk layout.
      if S.Loading and (P.State = 0) and not P.Decoding and not P.Rooted and
        (Length(P.PCM) = 0) and (Length(P.Data) = 0) then
        P.DiscardDecodedAudio;
      if P.SampleCount > Length(P.PCM) then
        raise EReadError.Create('Invalid snapshot media PCM');
      if not P.Streaming and not P.Decoding and (P.State >= 200) then
        if not (P.Info.Channels in [1, 2]) or (P.Info.SampleRate < 1) or (P.Info.SampleRate > 384000) or
          (P.SampleCount mod P.Info.Channels <> 0) or (P.FrameCount <> P.SampleCount div P.Info.Channels) or
          (P.Position < 0) or (P.Position > P.FrameCount * 44100) then
          raise EReadError.Create('Invalid snapshot media frame count');
      if S.Loading and P.Decoding and (P.SampleCount > 0) then
      begin
        var Ext := '.wav';
        if P.ContentType = 'audio/midi' then
          Ext := '.mid';
        P.Decoder := RestoreJ2MEDecoder(P.Data, Ext, P.SampleCount, P.Info.SampleRate, P.Info.Channels);
      end;

      if S.Loading then
      begin
        FPlayers.Add(Key, P);
        P := nil;
      end;
    finally
      if S.Loading then
        P.Free;
    end;
  end;

  var Events := FEvents.ToArray;
  N := Length(Events);
  S.Count(N, 65536);
  if S.Loading then
  begin
    FEvents.Clear;
    SetLength(Events, N);
  end;
  for var I := 0 to N - 1 do
  begin
    S.Int(Events[I].Listener);
    S.Int(Events[I].Player);
    S.Int(Events[I].EventName);
    S.Int(Events[I].Data);
    if S.Loading then
      FEvents.Enqueue(Events[I]);
  end;

  var Tones := FTones.ToArray;
  N := Length(Tones);
  S.Count(N, 65536);
  if S.Loading then
  begin
    FTones.Clear;
    SetLength(Tones, N);
  end;
  for var I := 0 to N - 1 do
  begin
    S.Int64Value(Tones[I].Remaining);
    S.RealValue(Tones[I].Phase);
    S.RealValue(Tones[I].Increment);
    S.Int(Tones[I].Volume);
    if S.Loading then
      FTones.Add(Tones[I]);
  end;
end;

initialization
  // The shared TimGM6mb bank is available on every target, even when no
  // beside-executable sf2 directory is deployed (notably mobile applications).
  SetDefaultMidiSoundFontResource(HInstance, 'RETROMUL_J2ME_SOUNDFONT');

end.

