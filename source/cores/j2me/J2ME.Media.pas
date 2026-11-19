unit J2ME.Media;

interface

uses
  Audio.Types, System.Classes, System.Types, JVM.StateIO, System.SysUtils,
  System.Generics.Collections, JVM.Types, JVM.ClassFile, JVM.Runtime,
  Audio.Decoder, Audio.Format.MIDI, Audio.Synthesis.SoundFont, J2ME.FileSystem,
  J2ME.Media.Video;

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
    Video: TJ2MEVideoStream;
    LiveMidi: IMidiSynthSource;
    MidiTiming: IMidiTimingSource;
    MidiDevice: Boolean;
    MidiStatus, MidiPendingCount: Integer;
    MidiPending: array[0..8] of Byte;
    Info: TAudioInfo;
    MetadataLoaded: Boolean;
    Metadata: TArray<TAudioMetadataField>;
    PCM: TArray<SmallInt>;
    SampleCount: Integer;
    FrameCount, CacheFrame, DecoderFrame: Int64;
    Position: Int64; // Source-frame position in 1/44100 frame units.
    destructor Destroy; override;
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
    FFiles: TJ2MEFileSystem;
    FPlayers: TObjectDictionary<Integer, TJ2MEMediaPlayer>;
    FEvents: TQueue<TJ2MEMediaEvent>;
    FTones: TList<TJ2METone>;
    FTimeBase: Integer;
    FVideoDirty: Boolean;
    FVideoBounds: TFunc<Integer, TRect>;
    FSeenGC: UInt64;
    FDecodeBuffer: TArray<SmallInt>;
    function VideoControlRef(P: TJ2MEMediaPlayer): TJVMValue;
    function VideoControlFor(P: TJ2MEMediaPlayer): TJVMObject;
    procedure VideoGeometry(Control: TJVMObject; P: TJ2MEMediaPlayer; out X, Y, W, H: Integer);
    function SyncVideoItem(Control: TJVMObject; P: TJ2MEMediaPlayer): Boolean;
    function VideoSnapshot(P: TJ2MEMediaPlayer; Control: TJVMObject; Param: Integer): TJVMValue;
    function InvokeVideoControl(const Name: string; const Args: TArray<TJVMValue>): TJVMValue;
    procedure OpenVideo(P: TJ2MEMediaPlayer);
    procedure SeekVideo(P: TJ2MEMediaPlayer; Time: Int64);
    procedure AdvanceVideoClock(P: TJ2MEMediaPlayer; Frames: Integer; var Mix: TArray<Int64>);
    procedure VideoError(P: TJ2MEMediaPlayer; const MessageText: string);
    function Player(Ref: Integer; AllowClosed: Boolean = False): TJ2MEMediaPlayer;
    function CreatePlayer(const Data: TBytes; const ContentType: string; MidiDevice: Boolean = False; ToneDevice: Boolean = False; Siemens: Boolean = False): Integer;
    function ListenerArray(Ref: Integer): string;
    function ListenerField(Ref: Integer): string;
    function MediaErrorClass(Ref: Integer): string;
    function ToneControlRef(P: TJ2MEMediaPlayer): TJVMValue;
    function StopTimeControlRef(P: TJ2MEMediaPlayer): TJVMValue;
    function GetStopTime(P: TJ2MEMediaPlayer): Int64;
    function StopPosition(P: TJ2MEMediaPlayer): Int64;
    procedure StopAtTime(P: TJ2MEMediaPlayer);
    function CheckStopTime(P: TJ2MEMediaPlayer): Boolean;
    procedure ConfigureTone(P: TJ2MEMediaPlayer; const Data: TBytes);
    procedure OpenMelody(P: TJ2MEMediaPlayer; out Frames: Int64);
    procedure SetToneSequence(P: TJ2MEMediaPlayer; const Value: TJVMValue);
    function MIDIControlRef(P: TJ2MEMediaPlayer): TJVMValue;
    function TempoControlRef(P: TJ2MEMediaPlayer): TJVMValue;
    function MetadataControlRef(P: TJ2MEMediaPlayer): TJVMValue;
    function InvokeMetadataControl(P: TJ2MEMediaPlayer; const Name: string; const Args: TArray<TJVMValue>): TJVMValue;
    function InvokeMIDIControl(P: TJ2MEMediaPlayer; const Name: string; const Args: TArray<TJVMValue>): TJVMValue;
    function InvokeTempoControl(P: TJ2MEMediaPlayer; const Name: string; const Args: TArray<TJVMValue>): TJVMValue;
    procedure ActivateMidi(P: TJ2MEMediaPlayer; Restoring: Boolean = False);
    procedure RenderLiveMidi(P: TJ2MEMediaPlayer; var Mix: TArray<Int64>; Frames: Integer);
    function RealizeStep(P: TJ2MEMediaPlayer; Generation: Integer): Boolean;
    procedure ReadStream(P: TJ2MEMediaPlayer; Source, Next: Int64);
    procedure PostEvent(P: TJ2MEMediaPlayer; const Name: string; Data: Integer);
    procedure TimeEvent(P: TJ2MEMediaPlayer; const Name: string; Time: Int64);
    procedure SetStarted(P: TJ2MEMediaPlayer; Started: Boolean);
    procedure StartPlayer(P: TJ2MEMediaPlayer);
    procedure StopPlayer(P: TJ2MEMediaPlayer; Notify: Boolean = True);
    function InvokeVodafoneSound(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function InvokeSamsungClip(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function PlaybackEndPosition(P: TJ2MEMediaPlayer; StopAt: Int64): Int64;
    procedure EndOfMedia(P: TJ2MEMediaPlayer);
    procedure Sweep;
  public
    class function SupportsLegacyClassLayout(C: TJVMClass; Count: Integer): Boolean; static;
    procedure TransferState(S: TJVMStateIO);
    constructor Create(VM: TJVM);
    destructor Destroy; override;
    procedure Install;
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function Render(Frames: Integer): TArray<SmallInt>;
    function VibrationActive: Boolean;
    procedure RenderMixInto(var Mix: TArray<Int64>; Frames: Integer);
    function RenderMix(Frames: Integer): TArray<Int64>;
    function TakeEvent(out Event: TJ2MEMediaEvent): Boolean;
    function PlayerUpdateDescriptor(Ref: Integer): string;
    procedure ReleaseEvent(const Event: TJ2MEMediaEvent);
    procedure ClearEvents;
    function UpdateVideo(Screen: Integer): Boolean;
    procedure DrawVideo(Screen: Integer; var Pixels: TArray<UInt32>; Width, Height: Integer);
    procedure DrawVideoItem(Item: Integer; var Pixels: TArray<UInt32>; Stride, X, Y: Integer; const Clip: TRect);
    property VideoBounds: TFunc<Integer, TRect> write FVideoBounds;
    procedure Shutdown;
    property Files: TJ2MEFileSystem write FFiles;
  end;

implementation

uses
  J2ME.ToneSequence, J2ME.IMelody, J2ME.SMAF, Audio.MP3.Source, Audio.Format.AMR,
  J2ME.Audio.State, System.Math, Java.Classes, Java.Bootstrap, J2ME.LCDUI,
  J2ME.UI.Data, J2ME.Compatibility;

{$R 'J2ME.SoundFont.res' 'J2ME.SoundFont.rc'}

{$Q-}{$R-}

const
  Media = 'javax/microedition/media/';
  PlayerAPI = Media + 'Player';
  PlayerImpl = 'org/retromul/media/Player';
  Manager = Media + 'Manager';
  Controllable = Media + 'Controllable';
  Control = Media + 'Control';
  GUIControlAPI = Media + 'control/GUIControl';
  DisplayModeAPI = 'com/sonyericsson/media/control/DisplayModeControl';
  VideoTransformShift = 4;
  VideoTransformMask = 7 shl VideoTransformShift;
  UseDirectVideo = 1;
  VideoControlAPI = Media + 'control/VideoControl';
  FramePositioningAPI = Media + 'control/FramePositioningControl';
  VideoControlImpl = 'org/retromul/media/VideoControl';
  VideoControlKey = '$media.videoControl';
  VideoItemClass = 'org/retromul/media/VideoItem';
  UseGUIPrimitive = 0;
  VideoClockRate = J2MEVideoClockRate;
  VideoLimit = 4;
  VolumeAPI = Media + 'control/VolumeControl';
  VolumeImpl = 'org/retromul/media/VolumeControl';
  MIDIAPI = Media + 'control/MIDIControl';
  MIDIImpl = 'org/retromul/media/MIDIControl';
  MIDIControlKey = '$media.midiControl';
  RateAPI = Media + 'control/RateControl';
  TempoAPI = Media + 'control/TempoControl';
  TempoImpl = 'org/retromul/media/TempoControl';
  TempoControlKey = '$media.tempoControl';
  RestartTempoKey = '$media.restartTempo';
  MetadataAPI = Media + 'control/MetaDataControl';
  MetadataImpl = 'org/retromul/media/MetaDataControl';
  MetadataControlKey = '$media.metadataControl';
  MP3ContentType = 'audio/mpeg';
  MIDILocator = 'device://midi';
  ToneLocator = 'device://tone';
  ToneAPI = Media + 'control/ToneControl';
  ToneImpl = 'org/retromul/media/ToneControl';
  ToneControlKey = '$media.toneControl';
  StopTimeAPI = Media + 'control/StopTimeControl';
  StopTimeImpl = 'org/retromul/media/StopTimeControl';
  StopTimeControlKey = '$media.stopTimeControl';
  StopTimeKey = '$media.stopTime';
  StopTimeReset = High(Int64);
  StoppedAtTime = 'stoppedAtTime';
  Listener = Media + 'PlayerListener';
  SiemensMedia = 'com/siemens/mp/media/';
  SiemensManager = SiemensMedia + 'Manager';
  SiemensPlayer = SiemensMedia + 'Player';
  SiemensListener = SiemensMedia + 'PlayerListener';
  SiemensPlayerImpl = 'org/retromul/media/SiemensPlayer';
  SiemensException = SiemensMedia + 'MediaException';
  SiemensControl = SiemensMedia + 'Control';
  SiemensControllable = SiemensMedia + 'Controllable';
  SiemensVolume = SiemensMedia + 'control/VolumeControl';
  SiemensTone = SiemensMedia + 'control/ToneControl';
  SiemensTimeBase = SiemensMedia + 'TimeBase';
  SiemensControlPlayerKey = '$media.siemensPlayer';
  SiemensPlayerDesc = 'L' + SiemensPlayer + ';';
  SiemensControlDesc = 'L' + SiemensControl + ';';
  SiemensTimeBaseDesc = 'L' + SiemensTimeBase + ';';
  SamsungClip = 'com/samsung/util/AudioClip';
  SamsungPlayerDesc = 'L' + PlayerImpl + ';';
  SamsungClipPlayer = SamsungClip + '.$player:' + SamsungPlayerDesc;
  VodafoneSound = 'com/vodafone/v10/sound/Sound';
  VodafonePlayer = 'com/vodafone/v10/sound/SoundPlayer';
  VodafoneTrack = 'com/vodafone/v10/sound/SoundTrack';
  VodafoneSoundDesc = 'L' + VodafoneSound + ';';
  VodafonePlayerDesc = 'L' + VodafonePlayer + ';';
  VodafoneTrackDesc = 'L' + VodafoneTrack + ';';
  VodafoneBackingDesc = 'L' + PlayerImpl + ';';
  VodafonePath = VodafoneSound + '.$path:Ljava/lang/String;';
  VodafoneBacking = VodafoneTrack + '.$player:' + VodafoneBackingDesc;
  VodafoneDisposed = VodafoneTrack + '.$disposed:Z';
  VodafoneRequest = VodafoneTrack + '.$request:I';
  TimeBase = Media + 'TimeBase';
  TimeBaseImpl = 'org/retromul/media/TimeBase';
  PlayerDesc = 'Ljavax/microedition/media/Player;';
  VolumeDesc = 'Ljavax/microedition/media/control/VolumeControl;';
  MaxEncodedMediaBytes = 64 * 1024 * 1024;
  MaxClipSamples = 8 * 1024 * 1024;
  MaxTotalSamples = 32 * 1024 * 1024;

function MediaEventLiteral(const FieldName: string): string;
begin
  Result := '';
  for var Part in FieldName.ToLowerInvariant.Split(['_']) do
    if Result = '' then
      Result := Part
    else
      Result := Result + UpperCase(Copy(Part, 1, 1)) + Copy(Part, 2, MaxInt);
end;

function IsMP3ContentType(const ContentType: string): Boolean;
begin
  Result := (ContentType = MP3ContentType) or (ContentType = 'audio/mp3') or
    (ContentType = 'audio/x-mp3') or (ContentType = 'audio/x-mpeg');
end;

function IsAMRContentType(const ContentType: string): Boolean;
begin
  Result := (ContentType = AMRNarrowbandContentType) or (ContentType = AMRWidebandContentType);
end;

function MediaDecoderExtension(const ContentType: string): string;
begin
  if ContentType = 'audio/midi' then
    Exit('.mid');
  if ContentType = SMAFContentType then
    Exit('.mmf');
  if ContentType = MP3ContentType then
    Exit('.mp3');
  if IsAMRContentType(ContentType) then
    Exit('.amr');
  if J2MEContainerAudioType(ContentType) then
    Exit('.m4a');
  Result := '.wav';
end;

class function TJ2MEMedia.SupportsLegacyClassLayout(C: TJVMClass; Count: Integer): Boolean;
begin
  if C.Name = Listener then
    Exit((Count = 9) and (C.Fields.Count = 10) and
      (C.Fields[Count].Name = 'STOPPED_AT_TIME'));
  Result := False;
  if (C.Name <> Manager) or (Count <> 1) or (C.Fields.Count <> 2) then
    Exit;
  Result := (C.Fields[0].Name = 'TONE_DEVICE_LOCATOR') and
    (C.Fields[1].Name = 'MIDI_DEVICE_LOCATOR');
  for var Field in C.Fields do
    Result := Result and (Field.Descriptor = 'Ljava/lang/String;') and
      (Field.Access = JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
end;

destructor TJ2MEMediaPlayer.Destroy;
begin
  Video.Free;
  inherited;
end;

procedure TJ2MEMediaPlayer.DiscardDecodedAudio;
begin
  MidiTiming := nil;
  LiveMidi := nil;
  Decoder := nil;
  MidiStatus := 0;
  MidiPendingCount := 0;
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
  begin
    var UnitsPerSecond := Int64(44100) * Info.SampleRate;
    Result := Position div UnitsPerSecond * 1000000 +
      Position mod UnitsPerSecond * 1000000 div UnitsPerSecond;
  end;
end;

function TJ2MEMediaPlayer.Duration: Int64;
begin
  if (ContentType = J2METoneContentType) and (Length(Data) = 0) then
    Exit(0);
  Result := -1;
  if (State >= 200) and not MidiDevice then
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

  procedure PlayerMethods(abstract: Boolean; Siemens: Boolean = False);

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
    if Siemens then
    begin
      for var Name in ['addPlayerListener', 'removePlayerListener'] do
        Add(Name, '(L' + SiemensListener + ';)V');
      Add('getControl', '(Ljava/lang/String;)' + SiemensControlDesc);
      Add('getControls', '()[' + SiemensControlDesc);
      Add('setTimeBase', '(' + SiemensTimeBaseDesc + ')V');
      Add('getTimeBase', '()' + SiemensTimeBaseDesc);
    end
    else
    begin
      for var Name in ['addPlayerListener', 'removePlayerListener'] do
        Add(Name, '(L' + Listener + ';)V');
      Add('getControl', '(Ljava/lang/String;)Ljavax/microedition/media/Control;');
      Add('getControls', '()[Ljavax/microedition/media/Control;');
      Add('setTimeBase', '(Ljavax/microedition/media/TimeBase;)V');
      Add('getTimeBase', '()Ljavax/microedition/media/TimeBase;');
    end;
    if abstract then
      for var Name in ['realize', 'prefetch', 'start'] do
        Add(Name, '()V');
  end;

  procedure MIDIMethods(IsAbstract: Boolean);

    procedure Add(const Name, Desc: string);
    begin
      if IsAbstract then
        AbstractMethod(Name, Desc)
      else
        Native(Name, Desc);
    end;

  begin
    Add('shortMidiEvent', '(III)V');
    Add('longMidiEvent', '([BII)I');
    Add('setChannelVolume', '(II)V');
    Add('getChannelVolume', '(I)I');
    Add('setProgram', '(III)V');
    Add('isBankQuerySupported', '()Z');
    Add('getProgram', '(I)[I');
    Add('getBankList', '(Z)[I');
    Add('getProgramList', '(I)[I');
    Add('getProgramName', '(II)Ljava/lang/String;');
    Add('getKeyName', '(III)Ljava/lang/String;');
  end;

  procedure ToneInterface(const Owner, BaseControl: string);
  begin
    B := TJavaClassBuilder.Create(Owner, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [BaseControl];
    var ToneNames: TArray<string> := ['SILENCE', 'VERSION', 'TEMPO', 'RESOLUTION', 'BLOCK_START',
        'BLOCK_END', 'PLAY_BLOCK', 'SET_VOLUME', 'REPEAT', 'C4'];
    for var I := 0 to High(ToneNames) do
    begin
      B.Field(ToneNames[I], 'B', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      if ToneNames[I] = 'C4' then
        B.JavaClass.Fields.Last.Value := TJVMValue.Int(60)
      else
        B.JavaClass.Fields.Last.Value := TJVMValue.Int(-1 - I);
    end;
    AbstractMethod('setSequence', '([B)V');
    Done;
  end;

  procedure PlayerImplementation(const Owner, API, ListenerAPI: string);
  begin
    B := TJavaClassBuilder.Create(Owner, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [API];
    B.Field('$volume', VolumeDesc, JVM_ACC_PRIVATE);
    B.Field('$listeners', '[L' + ListenerAPI + ';', JVM_ACC_PRIVATE);
    PlayerMethods(False, API = SiemensPlayer);
    Native('$beginRealize', '()I', JVM_ACC_PRIVATE);
    Native('$realizeStep', '(I)Z', JVM_ACC_PRIVATE);
    Native('$prefetch', '()V', JVM_ACC_PRIVATE);
    Native('$start', '()V', JVM_ACC_PRIVATE);
    // Parsing/rendering a MIDI is split into bounded native decode blocks. The
    // surrounding guest loop preserves budgets, stop, cancellation and GC.
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Owner, '$beginRealize', '()I'));
    B.Emit([$3C]);
    B.Mark('loop');
    B.Emit([$2A, $1B]);
    B.Ref($B7, B.Member(Owner, '$realizeStep', '(I)Z'));
    B.Jump($9A, 'done');
    B.Ref($B8, B.Member('java/lang/Thread', 'yield', '()V'));
    B.Jump($A7, 'loop');
    B.Mark('done');
    B.Emit([$B1]);
    B.Finish('realize', '()V', JVM_ACC_PUBLIC, 2, 2);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B6, B.Member(Owner, 'realize', '()V'));
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Owner, '$prefetch', '()V'));
    B.Emit([$B1]);
    B.Finish('prefetch', '()V', JVM_ACC_PUBLIC, 1, 1);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B6, B.Member(Owner, 'prefetch', '()V'));
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Owner, '$start', '()V'));
    B.Emit([$B1]);
    B.Finish('start', '()V', JVM_ACC_PUBLIC, 1, 1);
    Done;
  end;

  procedure SamsungClipMethods;
  begin
    B := TJavaClassBuilder.Create(SamsungClip, 'java/lang/Object', JVM_ACC_PUBLIC);
    IntConstant('TYPE_MMF', 1);
    IntConstant('TYPE_MP3', 2);
    IntConstant('TYPE_MIDI', 3);
    B.Field('$player', SamsungPlayerDesc, JVM_ACC_PRIVATE);
    B.Field('$active', SamsungPlayerDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    B.Field('$paused', 'Z', JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    Native('<init>', '(ILjava/lang/String;)V');
    Native('<init>', '(I[BII)V');
    Native('isSupported', '()Z', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    for var Name in ['stop', 'pause', 'resume'] do
      Native(Name, '()V');
    Native('$validatePlay', '(II)V', JVM_ACC_PRIVATE);
    Native('$play', '(II)V', JVM_ACC_PRIVATE);
    // Reuse MMAPI's resumable decode loop before exchanging the active clip.
    B.Start;
    B.Emit([$2A, $1B, $1C]);
    B.Ref($B7, B.Member(SamsungClip, '$validatePlay', '(II)V'));
    B.Emit([$2A]);
    B.Ref($B4, B.Member(SamsungClip, '$player', SamsungPlayerDesc, 9));
    B.Ref($B6, B.Member(PlayerImpl, 'prefetch', '()V'));
    B.Emit([$2A, $1B, $1C]);
    B.Ref($B7, B.Member(SamsungClip, '$play', '(II)V'));
    B.Emit([$B1]);
    B.Finish('play', '(II)V', JVM_ACC_PUBLIC, 3, 3);
    Done;
  end;

  procedure VodafoneSoundMethods;
  begin
    B := TJavaClassBuilder.Create(VodafoneSound, 'java/lang/Object', JVM_ACC_PUBLIC);
    B.Field('$path', 'Ljava/lang/String;', JVM_ACC_PRIVATE);
    Native('<init>', '(Ljava/lang/String;)V');
    Done;

    B := TJavaClassBuilder.Create(VodafonePlayer, 'java/lang/Object', JVM_ACC_PUBLIC);
    B.Field('$instance', VodafonePlayerDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    Native('getPlayer', '()' + VodafonePlayerDesc, JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('getTrack', '()' + VodafoneTrackDesc);
    Native('disposeTrack', '(' + VodafoneTrackDesc + ')V');
    Done;

    B := TJavaClassBuilder.Create(VodafoneTrack, 'java/lang/Object', JVM_ACC_PUBLIC);
    B.Field('$player', VodafoneBackingDesc, JVM_ACC_PRIVATE);
    B.Field('$disposed', 'Z', JVM_ACC_PRIVATE);
    B.Field('$request', 'I', JVM_ACC_PRIVATE);
    Native('setSound', '(' + VodafoneSoundDesc + ')V');
    Native('removeSound', '()V');
    Native('stop', '()V');
    Native('$prepare', '(I)' + VodafoneBackingDesc, JVM_ACC_PRIVATE);
    Native('$play', '(' + VodafoneBackingDesc + 'II)V', JVM_ACC_PRIVATE);

    // Prefetch can yield. Recheck the attachment and stop request before
    // starting in case another guest thread changed the track.
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, B.Member(VodafoneTrack, '$request', 'I', 9));
    B.Emit([$3E, $2A, $1B]);
    B.Ref($B7, B.Member(VodafoneTrack, '$prepare', '(I)' + VodafoneBackingDesc));
    B.Emit([$4D, $2C]);
    B.Ref($B6, B.Member(PlayerImpl, 'prefetch', '()V'));
    B.Emit([$2A, $2C, $1B, $1D]);
    B.Ref($B7, B.Member(VodafoneTrack, '$play', '(' + VodafoneBackingDesc + 'II)V'));
    B.Emit([$B1]);
    B.Finish('play', '(I)V', JVM_ACC_PUBLIC, 4, 4);
    Done;
  end;

  procedure ManagerMethods(const Owner, ResultDesc, TimeDesc: string);
  begin
    B := TJavaClassBuilder.Create(Owner, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    StringConstant('TONE_DEVICE_LOCATOR', ToneLocator);
    StringConstant('MIDI_DEVICE_LOCATOR', MIDILocator);
    Native('getSupportedContentTypes', '(Ljava/lang/String;)[Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('getSupportedProtocols', '(Ljava/lang/String;)[Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('createPlayer', '(Ljava/lang/String;)' + ResultDesc, JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('$create', '([BLjava/lang/String;)' + ResultDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    Native('$stream', '(Ljava/io/InputStream;)V', JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    Native('playTone', '(III)V', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('getSystemTimeBase', '()' + TimeDesc, JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    // InputStream reads stay virtual, including custom guest streams/yields.
    B.Start;
    B.Emit([$2A]);
    B.Ref($B8, B.Member(Owner, '$stream', '(Ljava/io/InputStream;)V'));
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
    B.Ref($B8, B.Member(Owner, '$create', '([BLjava/lang/String;)' + ResultDesc));
    B.Emit([$B0]);
    B.Finish('createPlayer', '(Ljava/io/InputStream;Ljava/lang/String;)' + ResultDesc, JVM_ACC_PUBLIC or JVM_ACC_STATIC, 4, 5);
    Done;
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(Media + 'MediaException', 'java/lang/Exception');
    Native('<init>', '()V');
    Native('<init>', '(Ljava/lang/String;)V');
    Done;
    B := TJavaClassBuilder.Create(SiemensException, 'java/lang/Exception');
    Native('<init>', '()V');
    Native('<init>', '(Ljava/lang/String;)V');
    Done;
    B := TJavaClassBuilder.Create(SiemensControl, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    Done;
    B := TJavaClassBuilder.Create(SiemensControllable, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    AbstractMethod('getControl', '(Ljava/lang/String;)' + SiemensControlDesc);
    AbstractMethod('getControls', '()[' + SiemensControlDesc);
    Done;
    B := TJavaClassBuilder.Create(SiemensPlayer, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [SiemensControllable];
    IntConstant('CLOSED', 0);
    IntConstant('UNREALIZED', 100);
    IntConstant('REALIZED', 200);
    IntConstant('PREFETCHED', 300);
    IntConstant('STARTED', 400);
    B.Field('TIME_UNKNOWN', 'J', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Long(-1);
    PlayerMethods(True, True);
    Done;
    B := TJavaClassBuilder.Create(SiemensListener, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    for var Name in ['STARTED', 'STOPPED', 'CLOSED', 'ERROR', 'END_OF_MEDIA', 'DURATION_UPDATED', 'VOLUME_CHANGED', 'BUFFERING_STARTED', 'BUFFERING_STOPPED', 'DEVICE_AVAILABLE', 'DEVICE_UNAVAILABLE', 'RECORD_ERROR', 'RECORD_STARTED', 'RECORD_STOPPED', 'SIZE_CHANGED', 'STOPPED_AT_TIME'] do
      StringConstant(Name, MediaEventLiteral(Name));
    AbstractMethod('playerUpdate', '(' + SiemensPlayerDesc + 'Ljava/lang/String;Ljava/lang/Object;)V');
    Done;
    B := TJavaClassBuilder.Create(SiemensTimeBase, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    AbstractMethod('getTime', '()J');
    Done;
    B := TJavaClassBuilder.Create(SiemensVolume, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [SiemensControl];
    AbstractMethod('setLevel', '(I)I');
    AbstractMethod('getLevel', '()I');
    AbstractMethod('setMute', '(Z)V');
    AbstractMethod('isMuted', '()Z');
    Done;
    ToneInterface(SiemensTone, SiemensControl);
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
    B := TJavaClassBuilder.Create(GUIControlAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [Control];
    IntConstant('USE_GUI_PRIMITIVE', UseGUIPrimitive);
    AbstractMethod('initDisplayMode', '(ILjava/lang/Object;)Ljava/lang/Object;');
    Done;
    B := TJavaClassBuilder.Create(VideoControlAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [GUIControlAPI];
    IntConstant('USE_DIRECT_VIDEO', UseDirectVideo);
    AbstractMethod('initDisplayMode', '(ILjava/lang/Object;)Ljava/lang/Object;');
    for var Name in ['getDisplayX', 'getDisplayY', 'getDisplayWidth', 'getDisplayHeight', 'getSourceWidth', 'getSourceHeight'] do
      AbstractMethod(Name, '()I');
    for var Name in ['setDisplayLocation', 'setDisplaySize'] do
      AbstractMethod(Name, '(II)V');
    AbstractMethod('setVisible', '(Z)V');
    AbstractMethod('setDisplayFullScreen', '(Z)V');
    AbstractMethod('getSnapshot', '(Ljava/lang/String;)[B');
    Done;
    B := TJavaClassBuilder.Create(DisplayModeAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [Control];
    AbstractMethod('setDisplayMode', '(I)V');
    AbstractMethod('getDisplayMode', '()I');
    Done;
    B := TJavaClassBuilder.Create(FramePositioningAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [Control];
    AbstractMethod('mapFrameToTime', '(I)J');
    AbstractMethod('mapTimeToFrame', '(J)I');
    AbstractMethod('seek', '(I)I');
    AbstractMethod('skip', '(I)I');
    Done;
    B := TJavaClassBuilder.Create(VideoControlImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [VideoControlAPI, DisplayModeAPI, FramePositioningAPI];
    B.Field('$player', PlayerDesc, JVM_ACC_PRIVATE);
    Native('initDisplayMode', '(ILjava/lang/Object;)Ljava/lang/Object;');
    for var Name in ['getDisplayX', 'getDisplayY', 'getDisplayWidth', 'getDisplayHeight', 'getSourceWidth', 'getSourceHeight'] do
      Native(Name, '()I');
    for var Name in ['setDisplayLocation', 'setDisplaySize'] do
      Native(Name, '(II)V');
    Native('setVisible', '(Z)V');
    Native('setDisplayFullScreen', '(Z)V');
    Native('getSnapshot', '(Ljava/lang/String;)[B');
    Native('setDisplayMode', '(I)V');
    Native('getDisplayMode', '()I');
    Native('mapFrameToTime', '(I)J');
    Native('mapTimeToFrame', '(J)I');
    Native('seek', '(I)I');
    Native('skip', '(I)I');
    Done;
    B := TJavaClassBuilder.Create(VideoItemClass, J2MEUI + 'Item', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    Done;
    B := TJavaClassBuilder.Create(VolumeAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [Control];
    AbstractMethod('setLevel', '(I)I');
    AbstractMethod('getLevel', '()I');
    AbstractMethod('setMute', '(Z)V');
    AbstractMethod('isMuted', '()Z');
    Done;
    B := TJavaClassBuilder.Create(MIDIAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [Control];
    IntConstant('NOTE_ON', $90);
    IntConstant('CONTROL_CHANGE', $B0);
    MIDIMethods(True);
    Done;
    B := TJavaClassBuilder.Create(MIDIImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [MIDIAPI];
    B.Field('$player', PlayerDesc, JVM_ACC_PRIVATE);
    MIDIMethods(False);
    Done;
    B := TJavaClassBuilder.Create(RateAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [Control];
    for var Name in ['getRate', 'getMinRate', 'getMaxRate'] do
      AbstractMethod(Name, '()I');
    AbstractMethod('setRate', '(I)I');
    Done;
    B := TJavaClassBuilder.Create(TempoAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [RateAPI];
    AbstractMethod('getTempo', '()I');
    AbstractMethod('setTempo', '(I)I');
    Done;
    B := TJavaClassBuilder.Create(TempoImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [TempoAPI];
    B.Field('$player', PlayerDesc, JVM_ACC_PRIVATE);
    for var Name in ['getRate', 'getMinRate', 'getMaxRate', 'getTempo'] do
      Native(Name, '()I');
    for var Name in ['setRate', 'setTempo'] do
      Native(Name, '(I)I');
    Done;
    B := TJavaClassBuilder.Create(MetadataAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [Control];
    StringConstant('AUTHOR_KEY', 'author');
    StringConstant('COPYRIGHT_KEY', 'copyright');
    StringConstant('DATE_KEY', 'date');
    StringConstant('TITLE_KEY', 'title');
    AbstractMethod('getKeys', '()[Ljava/lang/String;');
    AbstractMethod('getKeyValue', '(Ljava/lang/String;)Ljava/lang/String;');
    Done;
    B := TJavaClassBuilder.Create(MetadataImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [MetadataAPI];
    B.Field('$player', PlayerDesc, JVM_ACC_PRIVATE);
    Native('getKeys', '()[Ljava/lang/String;');
    Native('getKeyValue', '(Ljava/lang/String;)Ljava/lang/String;');
    Done;
    B := TJavaClassBuilder.Create(Listener, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    for var Name in ['STARTED', 'STOPPED', 'CLOSED', 'ERROR', 'DURATION_UPDATED', 'END_OF_MEDIA', 'VOLUME_CHANGED', 'DEVICE_AVAILABLE', 'DEVICE_UNAVAILABLE'] do
      StringConstant(Name, MediaEventLiteral(Name));
    StringConstant('STOPPED_AT_TIME', StoppedAtTime);
    AbstractMethod('playerUpdate', '(' + PlayerDesc + 'Ljava/lang/String;Ljava/lang/Object;)V');
    Done;
    B := TJavaClassBuilder.Create(TimeBase, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    AbstractMethod('getTime', '()J');
    Done;
    B := TJavaClassBuilder.Create(TimeBaseImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [TimeBase, SiemensTimeBase];
    Native('getTime', '()J');
    Done;
    FTimeBase := FVM.NewObject(TimeBaseImpl);
    FVM.AddRoot(FTimeBase);
    B := TJavaClassBuilder.Create(VolumeImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [VolumeAPI, SiemensVolume];
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
    ToneInterface(ToneAPI, Control);

    B := TJavaClassBuilder.Create(ToneImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [ToneAPI, SiemensTone];
    B.Field('$player', PlayerDesc, JVM_ACC_PRIVATE);
    Native('setSequence', '([B)V');
    Done;

    B := TJavaClassBuilder.Create(StopTimeAPI, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    B.JavaClass.Interfaces := [Control];
    B.Field('RESET', 'J', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Long(StopTimeReset);
    AbstractMethod('getStopTime', '()J');
    AbstractMethod('setStopTime', '(J)V');
    Done;

    B := TJavaClassBuilder.Create(StopTimeImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [StopTimeAPI];
    B.Field('$player', PlayerDesc, JVM_ACC_PRIVATE);
    Native('getStopTime', '()J');
    Native('setStopTime', '(J)V');
    Done;

    PlayerImplementation(PlayerImpl, PlayerAPI, Listener);
    PlayerImplementation(SiemensPlayerImpl, SiemensPlayer, SiemensListener);
    ManagerMethods(Manager, PlayerDesc, 'Ljavax/microedition/media/TimeBase;');
    ManagerMethods(SiemensManager, SiemensPlayerDesc, SiemensTimeBaseDesc);
    SamsungClipMethods;
    VodafoneSoundMethods;
  finally
    B.Free;
  end;
end;

function TJ2MEMedia.Handles(const Owner: string): Boolean;
begin
  Result := (Owner = Manager) or (Owner = SiemensManager) or (Owner = SamsungClip) or
    (Owner = VodafoneSound) or (Owner = VodafonePlayer) or (Owner = VodafoneTrack) or
    (Owner = PlayerImpl) or (Owner = SiemensPlayerImpl) or (Owner = VolumeImpl) or (Owner = ToneImpl) or
    (Owner = MIDIImpl) or (Owner = TempoImpl) or (Owner = StopTimeImpl) or
    (Owner = MetadataImpl) or (Owner = TimeBaseImpl) or (Owner = VideoControlImpl);
end;

function TJ2MEMedia.ListenerArray(Ref: Integer): string;
begin
  if FVM.GetObject(Ref).ClassName = SiemensPlayerImpl then
    Exit('[L' + SiemensListener + ';');
  Result := '[L' + Listener + ';';
end;

function TJ2MEMedia.ListenerField(Ref: Integer): string;
begin
  Result := FVM.GetObject(Ref).ClassName + '.$listeners:' + ListenerArray(Ref);
end;

function TJ2MEMedia.MediaErrorClass(Ref: Integer): string;
begin
  if FVM.GetObject(Ref).ClassName = SiemensPlayerImpl then
    Exit(SiemensException);
  Result := Media + 'MediaException';
end;

function TJ2MEMedia.PlayerUpdateDescriptor(Ref: Integer): string;
begin
  if FVM.GetObject(Ref).ClassName = SiemensPlayerImpl then
    Exit('(' + SiemensPlayerDesc + 'Ljava/lang/String;Ljava/lang/Object;)V');
  Result := '(' + PlayerDesc + 'Ljava/lang/String;Ljava/lang/Object;)V';
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
    begin
      if FPlayers[Ref].Video <> nil then
        FVideoDirty := True;
      FPlayers.Remove(Ref);
    end;
end;

function TJ2MEMedia.CreatePlayer(const Data: TBytes; const ContentType: string; MidiDevice, ToneDevice, Siemens: Boolean): Integer;
var
  P: TJ2MEMediaPlayer;
  Name: string;
  Ref, Live: Integer;
  Bytes: Int64;
begin
  var ErrorClass := Media + 'MediaException';
  var Impl := PlayerImpl;
  if Siemens then
  begin
    ErrorClass := SiemensException;
    Impl := SiemensPlayerImpl;
  end;
  if Length(Data) > 16 * 1024 * 1024 then
    FVM.RaiseJava(ErrorClass, 'Encoded media memory limit');
  for var Attempt := 0 to 1 do
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
    if (Live < 128) and (Bytes <= MaxEncodedMediaBytes) then
      Break;
    if Attempt = 0 then
      // Vendor games may allocate and abandon a clip for every effect.
      FVM.CollectGarbage;
  end;
  if Live >= 128 then
    FVM.RaiseJava(ErrorClass, 'Live player limit');
  if Bytes > MaxEncodedMediaBytes then
    FVM.RaiseJava(ErrorClass, 'Encoded media memory limit');
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
      Name := 'audio/midi'
    else if (Length(Data) >= 4) and (TEncoding.ASCII.GetString(Data, 0, 4) = 'MMMD') then
      Name := SMAFContentType
    else if (Length(Data) >= 4) and (Data[0] = Byte(256 + J2METoneVersion)) and (Data[1] = 1) then
      Name := J2METoneContentType
    else if IsIMelody(Data) then
      Name := IMelodyContentType
    else if DetectAMR(Data) = TAMRKind.Narrowband then
      Name := AMRNarrowbandContentType
    else if DetectAMR(Data) = TAMRKind.Wideband then
      Name := AMRWidebandContentType
    else if IsMP3Audio(Data) then
      Name := MP3ContentType
    else if not Siemens then
      Name := DetectJ2MEVideoType(Data);
  end
  else if (not Siemens) and J2MEVideoContentType(Name) then
  begin
    var Detected := DetectJ2MEVideoType(Data);
    if J2MEContainerAudioType(Detected) then
      Name := Detected;
  end;
  if (Name = 'audio/wav') or (Name = 'audio/wave') then
    Name := 'audio/x-wav';
  if (Name = 'audio/x-midi') or (Name = 'audio/x-mid') or (Name = 'audio/sp-midi') then
    Name := 'audio/midi';
  if Name = SiemensSMAFContentType then
    Name := SMAFContentType;
  if IsMP3ContentType(Name) then
    Name := MP3ContentType;
  if IsIMelodyContentType(Name) then
    Name := IMelodyContentType;
  if (Name <> 'audio/x-wav') and (Name <> 'audio/midi') and (Name <> J2METoneContentType) and
    (Name <> IMelodyContentType) and
    (Name <> SMAFContentType) and (Name <> MP3ContentType) and
    not IsAMRContentType(Name) and
    (Siemens or not (J2MEVideoContentType(Name) or J2MEContainerAudioType(Name))) then
    FVM.RaiseJava(ErrorClass, 'Unsupported content type: ' + Name);
  if (Name = J2METoneContentType) and ((Length(Data) > J2METoneMaxBytes) or ((Length(Data) = 0) and not ToneDevice)) then
    FVM.RaiseJava(ErrorClass, 'Invalid tone sequence size');
  if (Name = IMelodyContentType) and ((Length(Data) = 0) or (Length(Data) > IMelodyMaxBytes)) then
    FVM.RaiseJava(ErrorClass, 'Invalid iMelody size');
  P := TJ2MEMediaPlayer.Create;
  try
    P.MidiDevice := MidiDevice;
    P.ContentType := Name;
    P.Data := Copy(Data);
    if Name = 'audio/x-wav' then
      P.Data := NormalizeJ2MECompatibilityWAV(P.Data);
    P.State := 100;
    P.Volume := 100;
    P.LoopCount := 1;
    P.LoopsLeft := 1;
    P.Reference := FVM.NewObject(Impl);
    Result := P.Reference;
    Ref := FVM.NewObject(VolumeImpl);
    if Siemens then
      FVM.GetObject(Ref).Fields.AddOrSetValue(SiemensControlPlayerKey, TJVMValue.Ref(Result))
    else
      FVM.GetObject(Ref).Fields[VolumeImpl + '.$player:' + PlayerDesc] := TJVMValue.Ref(Result);
    FVM.GetObject(Result).Fields[Impl + '.$volume:' + VolumeDesc] := TJVMValue.Ref(Ref);
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
    if J2MEVideoContentType(P.ContentType) then
    begin
      OpenVideo(P);
      P.Info.SampleRate := VideoClockRate;
      P.FrameCount := P.Video.Duration;
      P.Decoding := False;
      P.State := 200;
      TimeEvent(P, 'durationUpdated', P.Duration);
      Exit;
    end;
    if P.MidiDevice then
    begin
      P.Info.SampleRate := 44100;
      P.Info.Channels := 2;
      P.FrameCount := MidiDeviceFrameLimit;
      P.Decoding := False;
      P.State := 200;
      Exit;
    end;
    if P.ContentType = J2METoneContentType then
    begin
      ConfigureTone(P, P.Data);
      P.State := 200;
      if P.FrameCount <> 0 then
        TimeEvent(P, 'durationUpdated', P.Duration);
      Exit;
    end;
    if P.ContentType = IMelodyContentType then
    begin
      OpenMelody(P, P.FrameCount);
      P.Info := GetAudioInfo(P.Decoder);
      P.Streaming := True;
      P.Decoding := False;
      P.State := 200;
      TimeEvent(P, 'durationUpdated', P.Duration);
      Exit;
    end;
    if P.Decoder = nil then
    begin
      P.Decoder := OpenJ2MEDecoder(P.Data, MediaDecoderExtension(P.ContentType));
      P.Info := GetAudioInfo(P.Decoder);
      if (P.Info.SampleRate < 1) or (P.Info.SampleRate > 384000) or not (P.Info.Channels in [1, 2]) then
        raise EArgumentException.Create('Unsupported PCM format');
      // MIDI synthesis is expensive even for some short clips. A game can
      // realize several songs up front, so only validate and time them here.
      // Short WAV effects retain the decoded PCM path.
      if Length(P.Info.TrackDurations) > 0 then
      begin
        var Seconds := P.Info.TrackDurations[0];
        if not IsNan(Seconds) and not IsInfinite(Seconds) and (Seconds >= 0) and (Seconds <= 86402) then
        begin
          var Frames := Round(Seconds * P.Info.SampleRate);
          if (P.ContentType = 'audio/midi') or
            (((P.ContentType = MP3ContentType) or J2MEContainerAudioType(P.ContentType)) and
            (Frames > Int64(P.Info.SampleRate) * 2)) or
            (Frames > MaxClipSamples div P.Info.Channels) then
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
      FVM.RaiseJava(MediaErrorClass(P.Reference), E.Message);
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
  var BlockFrames := 4096;
  {$IFDEF ANDROID}
  if P.ContentType = 'audio/midi' then
    BlockFrames := 512;
  {$ENDIF}
  SetLength(FDecodeBuffer, BlockFrames * P.Info.Channels);
  Samples := FDecodeBuffer;
  var Seeker: IAudioSeekSource;
  if (P.Decoder = nil) or ((P.DecoderFrame > Start) and not Supports(P.Decoder, IAudioSeekSource, Seeker)) then
  begin
    if P.ContentType = J2METoneContentType then
    begin
      var Frames: Int64;
      P.Decoder := OpenJ2METoneSequence(P.Data, Frames);
      if Frames <> P.FrameCount then
        raise EJVMError.Create('Incompatible tone sequence duration');
    end
    else if P.ContentType = IMelodyContentType then
    begin
      var Frames: Int64;
      OpenMelody(P, Frames);
      if Frames <> P.FrameCount then
        raise EJVMError.Create('Incompatible iMelody duration');
    end
    else
      P.Decoder := OpenJ2MEDecoder(P.Data, MediaDecoderExtension(P.ContentType));
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
        Result := FVM.StopRequested or J2MEAudioThreadTerminated;
      end);
    if P.DecoderFrame <> Start then
      raise EJVMError.Create('Invalid streaming audio seek');
  end;
  while P.DecoderFrame < Start do
  begin
    if FVM.StopRequested or J2MEAudioThreadTerminated then
      raise EAbort.Create('Media seek cancelled');
    var Count := Integer(Min(Int64(BlockFrames), Start - P.DecoderFrame));
    var Read := P.Decoder.Render(Samples, Count);
    if (Read <= 0) or (Read > Count) then
      raise EJVMError.Create('Invalid streaming audio seek');
    Inc(P.DecoderFrame, Read);
  end;
  if FVM.StopRequested or J2MEAudioThreadTerminated then
    raise EAbort.Create('Media render cancelled');
  var Count := Integer(Min(Int64(BlockFrames), P.FrameCount - Start));
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
  if not FVM.GetObject(P.Reference).Fields.TryGetValue(ListenerField(P.Reference), Value) or (Value.AsRef = 0) then
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
  Value := FVM.GetObject(P.Reference).Fields[ListenerField(P.Reference)];
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

procedure TJ2MEMedia.StartPlayer(P: TJ2MEMediaPlayer);
begin
  if P.State = 400 then
    Exit;
  if P.State <> 300 then
    FVM.RaiseJava(MediaErrorClass(P.Reference), 'Player was not prefetched');
  // Completion exhausts the loop count even if the caller has since sought
  // away from the end. A stopped player still carries its remaining loops.
  if P.LoopsLeft = 0 then
    P.LoopsLeft := P.LoopCount;
  if P.Position >= Int64(P.FrameCount) * 44100 then
  begin
    P.Position := 0;
    if P.LiveMidi <> nil then
    begin
      SelectAudioTrack(P.Decoder, 0);
      if P.MidiTiming <> nil then
      begin
        var Tempo: TJVMValue;
        var Fields := FVM.GetObject(P.Reference).Fields;
        if Fields.TryGetValue(RestartTempoKey, Tempo) then
        begin
          P.MidiTiming.SetTempo(Tempo.AsInt);
          Fields.Remove(RestartTempoKey);
        end;
      end;
    end;
  end;
  P.State := 400;
  SetStarted(P, True);
  TimeEvent(P, 'started', P.MediaTime);
  if not CheckStopTime(P) and (P.FrameCount = 0) then
    EndOfMedia(P);
end;

procedure TJ2MEMedia.StopPlayer(P: TJ2MEMediaPlayer; Notify: Boolean);
begin
  if P.State <> 400 then
    Exit;
  P.State := 300;
  SetStarted(P, False);
  if Notify then
    TimeEvent(P, 'stopped', P.MediaTime);
end;

function TJ2MEMedia.PlaybackEndPosition(P: TJ2MEMediaPlayer; StopAt: Int64): Int64;
begin
  Result := P.FrameCount * 44100;
  if (P.ContentType <> 'audio/midi') or P.MidiDevice or
    (P.FrameCount <= MidiReleaseTailFrames) or (P.LoopsLeft in [0, 1]) then
    Exit;
  // Repeat at the SMF sequence end. Preserve a position or stop time inside
  // the release tail, including positions restored from older snapshots.
  var SequenceEnd := Result - Int64(MidiReleaseTailFrames) * 44100;
  if (P.Position <= SequenceEnd) and ((StopAt <= SequenceEnd) or (StopAt > Result)) then
    Result := SequenceEnd;
end;

procedure TJ2MEMedia.EndOfMedia(P: TJ2MEMediaPlayer);
begin
  TimeEvent(P, 'endOfMedia', P.MediaTime);
  if (P.FrameCount > 0) and ((P.LoopsLeft = -1) or (P.LoopsLeft > 1)) then
  begin
    if P.LoopsLeft > 1 then
      Dec(P.LoopsLeft);
    P.Position := 0;
    if P.LiveMidi <> nil then
      SelectAudioTrack(P.Decoder, 0);
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
    FreeAndNil(P.Video);
    P.DiscardDecodedAudio;
    P.MidiDevice := False;
    P.Data := nil;
    Inc(P.Generation);
  end;
end;

function MidiDataLength(Status: Integer): Integer;
begin
  case Status of
    $80..$BF, $E0..$EF, $F2:
      Result := 2;
    $C0..$DF, $F1, $F3:
      Result := 1;
  else
    Result := 0;
  end;
end;

function ValidMidiInputState(Status, Pending: Integer): Boolean;
begin
  if Status = $F0 then
    Exit(InRange(Pending, 0, 9));
  if Status = 0 then
    Exit(Pending = 0);
  Result := InRange(Status, $80, $F3) and InRange(Pending, 0, MidiDataLength(Status) - 1);
end;

function TJ2MEMedia.ToneControlRef(P: TJ2MEMediaPlayer): TJVMValue;
begin
  if P.ContentType <> J2METoneContentType then
    Exit(TJVMValue.Ref(0));
  var Fields := FVM.GetObject(P.Reference).Fields;
  if not Fields.TryGetValue(ToneControlKey, Result) then
  begin
    var Ref := FVM.NewObject(ToneImpl);
    if FVM.GetObject(P.Reference).ClassName = SiemensPlayerImpl then
      FVM.GetObject(Ref).Fields.AddOrSetValue(SiemensControlPlayerKey, TJVMValue.Ref(P.Reference))
    else
      FVM.GetObject(Ref).Fields[ToneImpl + '.$player:' + PlayerDesc] := TJVMValue.Ref(P.Reference);
    Result := TJVMValue.Ref(Ref);
    Fields.Add(ToneControlKey, Result);
  end;
end;

function TJ2MEMedia.StopTimeControlRef(P: TJ2MEMediaPlayer): TJVMValue;
begin
  var Fields := FVM.GetObject(P.Reference).Fields;
  if not Fields.TryGetValue(StopTimeControlKey, Result) then
  begin
    var Ref := FVM.NewObject(StopTimeImpl);
    FVM.GetObject(Ref).Fields[StopTimeImpl + '.$player:' + PlayerDesc] := TJVMValue.Ref(P.Reference);
    Result := TJVMValue.Ref(Ref);
    Fields.Add(StopTimeControlKey, Result);
  end;
end;

function TJ2MEMedia.GetStopTime(P: TJ2MEMediaPlayer): Int64;
var
  Value: TJVMValue;
begin
  Result := StopTimeReset;
  if FVM.GetObject(P.Reference).Fields.TryGetValue(StopTimeKey, Value) then
    Result := Value.AsLong;
end;

function TJ2MEMedia.StopPosition(P: TJ2MEMediaPlayer): Int64;
begin
  var Time := GetStopTime(P);
  if Time = StopTimeReset then
    Exit(High(Int64));
  if Time <= 0 then
    Exit(0);
  var UnitsPerSecond := Int64(44100) * P.Info.SampleRate;
  // Round up in the player's position units without multiplying a Java long by the sample rate.
  if Time div 1000000 > High(Int64) div UnitsPerSecond then
    Exit(High(Int64));
  var Whole := Time div 1000000 * UnitsPerSecond;
  var Fraction := (Time mod 1000000 * UnitsPerSecond + 999999) div 1000000;
  Result := Whole + Min(Fraction, High(Int64) - Whole);
end;

procedure TJ2MEMedia.StopAtTime(P: TJ2MEMediaPlayer);
begin
  FVM.GetObject(P.Reference).Fields.Remove(StopTimeKey);
  P.State := 300;
  if (P.FrameCount > 0) and (P.Position = P.FrameCount * 44100) and (P.LoopsLeft > 0) then
    Dec(P.LoopsLeft);
  SetStarted(P, False);
  TimeEvent(P, StoppedAtTime, P.MediaTime);
end;

function TJ2MEMedia.CheckStopTime(P: TJ2MEMediaPlayer): Boolean;
begin
  var Time := GetStopTime(P);
  Result := (P.State = 400) and (Time <> StopTimeReset) and (P.MediaTime >= Time);
  if Result then
    StopAtTime(P);
end;

procedure TJ2MEMedia.OpenMelody(P: TJ2MEMediaPlayer; out Frames: Int64);
begin
  P.Decoder := OpenIMelody(P.Data, Frames);
  P.DecoderFrame := 0;
end;

function TJ2MEMedia.VibrationActive: Boolean;
begin
  for var P in FPlayers.Values do
    if (P.State = 400) and (P.ContentType = IMelodyContentType) then
    begin
      var Effects: IIMelodyEffects;
      if Supports(P.Decoder, IIMelodyEffects, Effects) and Effects.VibratesAt(P.Position div 44100) then
        Exit(True);
    end;
  Result := False;
end;

procedure TJ2MEMedia.ConfigureTone(P: TJ2MEMediaPlayer; const Data: TBytes);
begin
  var Frames: Int64 := 0;
  var Source: IAudioSource := nil;
  if Length(Data) > 0 then
    Source := OpenJ2METoneSequence(Data, Frames);
  P.DiscardDecodedAudio;
  P.Data := Data;
  P.Decoder := Source;
  P.Info := Default(TAudioInfo);
  P.Info.SampleRate := J2METoneRate;
  P.Info.Channels := 1;
  P.FrameCount := Frames;
  P.Streaming := Frames > 0;
  P.LoopsLeft := P.LoopCount;
end;

procedure TJ2MEMedia.SetToneSequence(P: TJ2MEMediaPlayer; const Value: TJVMValue);
begin
  if P.State >= 300 then
    FVM.RaiseJava('java/lang/IllegalStateException', 'Tone player is prefetched or started');
  if Value.AsRef = 0 then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Null tone sequence');
  var ArrayObj := FVM.GetObject(Value.AsRef);
  var Count := ArrayObj.ElementCount;
  if (Count < 4) or (Count > J2METoneMaxBytes) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid tone sequence size');
  var Bytes := Count;
  for var Other in FPlayers.Values do
    if Other <> P then
      Inc(Bytes, Length(Other.Data));
  if Bytes > MaxEncodedMediaBytes then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Encoded media memory limit');

  var Data: TBytes;
  SetLength(Data, Count);
  for var I := 0 to Count - 1 do
    Data[I] := Byte(ArrayObj.ElementValues[I].AsInt);
  var Previous := P.Duration;
  try
    ConfigureTone(P, Data);
  except
    on E: EArgumentException do
      FVM.RaiseJava('java/lang/IllegalArgumentException', E.Message);
  end;
  if P.Duration <> Previous then
    TimeEvent(P, 'durationUpdated', P.Duration);
end;

function TJ2MEMedia.MIDIControlRef(P: TJ2MEMediaPlayer): TJVMValue;
begin
  if P.ContentType <> 'audio/midi' then
    Exit(TJVMValue.Ref(0));
  var Fields := FVM.GetObject(P.Reference).Fields;
  if not Fields.TryGetValue(MIDIControlKey, Result) then
  begin
    var Ref := FVM.NewObject(MIDIImpl);
    FVM.GetObject(Ref).Fields[MIDIImpl + '.$player:' + PlayerDesc] := TJVMValue.Ref(P.Reference);
    Result := TJVMValue.Ref(Ref);
    Fields.Add(MIDIControlKey, Result);
  end;
end;

procedure TJ2MEMedia.ActivateMidi(P: TJ2MEMediaPlayer; Restoring: Boolean);
begin
  if P.LiveMidi <> nil then
    Exit;
  try
    var Source: IAudioSource;
    if P.MidiDevice then
      Source := OpenMidiDevice
    else
      Source := OpenJ2MEDecoder(P.Data, '.mid');
    var Info := GetAudioInfo(Source);
    if (Info.SampleRate <> 44100) or (Info.Channels <> 2) then
      raise EArgumentException.Create('Unexpected MIDI PCM format');
    if P.MidiDevice then
    begin
      if P.FrameCount <> MidiDeviceFrameLimit then
        raise EArgumentException.Create('Invalid MIDI device duration');
    end
    else if (Length(Info.TrackDurations) = 0) or
      (Round(Info.TrackDurations[0] * 44100) <> P.FrameCount) then
      raise EArgumentException.Create('Incompatible MIDI duration');
    var Frame := P.Position div 44100;
    var Midi := Source as IMidiSynthSource;
    if Restoring or P.MidiDevice then
      Midi.RestoreCursor(Frame)
    else
    begin
      var Seeker := Source as IAudioSeekSource;
      if Seeker.SeekFrame(Frame,
        function: Boolean
        begin
          Result := FVM.StopRequested or J2MEAudioThreadTerminated;
        end) <> Frame then
        raise EArgumentException.Create('Invalid MIDI position');
    end;
    P.Decoder := Source;
    P.LiveMidi := Midi;
  except
    on E: Exception do
    begin
      if Restoring or (E is EAbort) then
        raise;
      FVM.RaiseJava(Media + 'MediaException', E.Message);
    end;
  end;
end;

procedure LoadMediaMetadata(P: TJ2MEMediaPlayer);

  procedure Add(const Key, Value: string);
  begin
    if Value = '' then
      Exit;
    var Index := Length(P.Metadata);
    SetLength(P.Metadata, Index + 1);
    P.Metadata[Index].Name := Key;
    P.Metadata[Index].Value := Value;
  end;

begin
  if P.MetadataLoaded then
    Exit;
  if (Length(P.Data) = 0) or (P.ContentType = J2METoneContentType) then
  begin
    P.MetadataLoaded := True;
    Exit;
  end;
  var Info := P.Info;
  // Snapshots preserve PCM and the original stream, with only the format
  // fields from Info. Reuse the restored decoder or reopen the media.
  if Info.FormatName = '' then
  begin
    var Decoder := P.Decoder;
    if Decoder = nil then
      Decoder := OpenJ2MEDecoder(P.Data, MediaDecoderExtension(P.ContentType));
    Info := GetAudioInfo(Decoder);
  end;
  Add('title', Info.Title);
  Add('author', Info.Artist);
  Add('copyright', Info.CopyrightText);
  var Date := '';
  for var Field in Info.Metadata do
    if (Field.Name = 'INFO / ICRD') or (Field.Name = 'TDRC') or
      ((Field.Name = 'TYER') and (Date = '')) then
      Date := Field.Value;
  Add('date', Date);
  P.MetadataLoaded := True;
end;

function TJ2MEMedia.MetadataControlRef(P: TJ2MEMediaPlayer): TJVMValue;
begin
  Result := TJVMValue.Ref(0);
  if P.State < 200 then
    Exit;
  LoadMediaMetadata(P);
  if Length(P.Metadata) = 0 then
    Exit;
  var Fields := FVM.GetObject(P.Reference).Fields;
  if not Fields.TryGetValue(MetadataControlKey, Result) then
  begin
    var Ref := FVM.NewObject(MetadataImpl);
    FVM.GetObject(Ref).Fields[MetadataImpl + '.$player:' + PlayerDesc] := TJVMValue.Ref(P.Reference);
    Result := TJVMValue.Ref(Ref);
    Fields.Add(MetadataControlKey, Result);
  end;
end;

function TJ2MEMedia.InvokeMetadataControl(P: TJ2MEMediaPlayer; const Name: string; const Args: TArray<TJVMValue>): TJVMValue;
begin
  LoadMediaMetadata(P);
  if Name = 'getKeys' then
  begin
    var Ref := FVM.NewArray('[Ljava/lang/String;', Length(P.Metadata));
    for var I := 0 to High(P.Metadata) do
      FVM.GetObject(Ref).ElementValues[I] := TJVMValue.Ref(FVM.NewString(P.Metadata[I].Name));
    Exit(TJVMValue.Ref(Ref));
  end;
  var Ref := Args[1].AsRef;
  if Ref <> 0 then
  begin
    var Key := FVM.GetObject(Ref).Text;
    for var Field in P.Metadata do
      if Field.Name = Key then
        Exit(TJVMValue.Ref(FVM.NewString(Field.Value)));
  end;
  Result := TJVMValue.Ref(0);
  FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid media metadata key');
end;

function TJ2MEMedia.TempoControlRef(P: TJ2MEMediaPlayer): TJVMValue;
begin
  if P.MidiDevice or (P.ContentType <> 'audio/midi') then
    Exit(TJVMValue.Ref(0));
  var Fields := FVM.GetObject(P.Reference).Fields;
  if not Fields.TryGetValue(TempoControlKey, Result) then
  begin
    var Ref := FVM.NewObject(TempoImpl);
    FVM.GetObject(Ref).Fields[TempoImpl + '.$player:' + PlayerDesc] := TJVMValue.Ref(P.Reference);
    Result := TJVMValue.Ref(Ref);
    Fields.Add(TempoControlKey, Result);
  end;
end;

function TJ2MEMedia.InvokeTempoControl(P: TJ2MEMediaPlayer; const Name: string; const Args: TArray<TJVMValue>): TJVMValue;
begin
  if Name = 'getMinRate' then
    Exit(TJVMValue.Int(MidiMinRate));
  if Name = 'getMaxRate' then
    Exit(TJVMValue.Int(MidiMaxRate));
  if P.MidiTiming = nil then
  begin
    ActivateMidi(P);
    P.MidiTiming := P.Decoder as IMidiTimingSource;
  end;
  if Name = 'getTempo' then
    Exit(TJVMValue.Int(P.MidiTiming.Tempo));
  if Name = 'setTempo' then
  begin
    Result := TJVMValue.Int(P.MidiTiming.SetTempo(Args[1].AsInt));
    // Preserve a new stopped-player override across the implicit rewind.
    if (P.State <> 400) and (P.Position = P.FrameCount * 44100) then
      FVM.GetObject(P.Reference).Fields.AddOrSetValue(RestartTempoKey, Result);
    Exit;
  end;
  if Name = 'getRate' then
    Exit(TJVMValue.Int(P.MidiTiming.Rate));
  if Name = 'setRate' then
    Exit(TJVMValue.Int(P.MidiTiming.SetRate(Args[1].AsInt)));
  raise EJVMError.Create('Unknown MIDI timing control method');
end;

function TJ2MEMedia.InvokeMIDIControl(P: TJ2MEMediaPlayer; const Name: string; const Args: TArray<TJVMValue>): TJVMValue;
var
  Synth: TSoundFontSynth;

  function Limited(Index, Minimum, Maximum: Integer): Integer;
  begin
    Result := Args[Index].AsInt;
    if not InRange(Result, Minimum, Maximum) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid MIDI argument');
  end;

  function IntArray(const Values: TArray<Integer>): TJVMValue;
  begin
    var Ref := FVM.NewArray('[I', Length(Values));
    var Arr := FVM.GetObject(Ref);
    for var I := 0 to High(Values) do
      Arr.ElementValues[I] := TJVMValue.Int(Values[I]);
    Result := TJVMValue.Ref(Ref);
  end;

  procedure Send(Status, A, B: Byte);
  begin
    if Status = $FF then
      Synth.Reset
    else if Status < $F0 then
      Synth.Message(Status, A, B);
  end;

  procedure Feed(DataByte: Byte);
  begin
    // Realtime messages may occur between the bytes of any other message.
    if DataByte >= $F8 then
    begin
      Send(DataByte, 0, 0);
      Exit;
    end;
    if (P.MidiStatus = $F0) and (DataByte = $F7) and (P.MidiPendingCount < Length(P.MidiPending)) then
    begin
      P.MidiPending[P.MidiPendingCount] := $F7;
      if IsMidiReset(P.MidiPending, 0, P.MidiPendingCount + 1) then
        Synth.Reset;
    end;
    if DataByte >= $80 then
    begin
      P.MidiPendingCount := 0;
      if (DataByte = $F0) or (MidiDataLength(DataByte) <> 0) then
        P.MidiStatus := DataByte
      else
        P.MidiStatus := 0;
      Exit;
    end;
    if P.MidiStatus = 0 then
      Exit;
    if P.MidiStatus = $F0 then
    begin
      // Only reset messages are recognized. Keep a bounded prefix of SysEx.
      if P.MidiPendingCount < Length(P.MidiPending) then
      begin
        P.MidiPending[P.MidiPendingCount] := DataByte;
        Inc(P.MidiPendingCount);
      end;
      Exit;
    end;
    P.MidiPending[P.MidiPendingCount] := DataByte;
    Inc(P.MidiPendingCount);
    if P.MidiPendingCount = MidiDataLength(P.MidiStatus) then
    begin
      var Second: Byte := 0;
      if P.MidiPendingCount = 2 then
        Second := P.MidiPending[1];
      Send(Byte(P.MidiStatus), P.MidiPending[0], Second);
      P.MidiPendingCount := 0;
      if P.MidiStatus >= $F0 then
        P.MidiStatus := 0;
    end;
  end;

begin
  Result := Default(TJVMValue);
  if Name = 'isBankQuerySupported' then
    Exit(TJVMValue.Int(1));
  if P.State < 300 then
    FVM.RaiseJava('java/lang/IllegalStateException', 'MIDI player not prefetched');
  if Name = 'shortMidiEvent' then
  begin
    var Status := Limited(1, $80, $FF);
    if Status in [$F0, $F7] then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'System exclusive requires longMidiEvent');
    var DataLength := MidiDataLength(Status);
    var A := Limited(2, 0, 127 * Ord(DataLength >= 1));
    var B := Limited(3, 0, 127 * Ord(DataLength = 2));
    ActivateMidi(P);
    Synth := P.LiveMidi.Synth;
    Send(Byte(Status), Byte(A), Byte(B));
    Exit;
  end;
  if Name = 'longMidiEvent' then
  begin
    if Args[1].AsRef = 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Null MIDI data');
    var Data := FVM.GetObject(Args[1].AsRef);
    var Offset := Args[2].AsInt;
    var Count := Args[3].AsInt;
    if (Offset < 0) or (Count < 0) or (Offset > Data.ElementCount) or (Count > Data.ElementCount - Offset) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid MIDI data range');
    if Count = 0 then
      Exit(TJVMValue.Int(0));
    ActivateMidi(P);
    Synth := P.LiveMidi.Synth;
    Count := Min(Count, 65536);
    for var I := Offset to Offset + Count - 1 do
      Feed(Byte(Data.ElementValues[I].AsInt));
    Exit(TJVMValue.Int(Count));
  end;
  if (Name = 'getChannelVolume') or (Name = 'setChannelVolume') or (Name = 'setProgram') then
  begin
    var Channel := Limited(1, 0, 15);
    var Volume := 0;
    var Bank := -1;
    var ProgramNumber := 0;
    if Name = 'setChannelVolume' then
      Volume := Limited(2, 0, 127);
    if Name = 'setProgram' then
    begin
      Bank := Limited(2, -1, 16383);
      ProgramNumber := Limited(3, 0, 127);
    end;
    ActivateMidi(P);
    Synth := P.LiveMidi.Synth;
    if Name = 'getChannelVolume' then
      Exit(TJVMValue.Int(Synth.ChannelVolume(Channel)));
    if Name = 'setChannelVolume' then
      Synth.Message(Byte($B0 or Channel), 7, Byte(Volume))
    else
    begin
      Bank := Max(Bank, 0);
      Synth.Message(Byte($B0 or Channel), 0, Byte(Bank shr 7));
      Synth.Message(Byte($B0 or Channel), 32, Byte(Bank and 127));
      Synth.Message(Byte($C0 or Channel), Byte(ProgramNumber), 0);
    end;
    Exit;
  end;
  if Name = 'getProgram' then
  begin
    var Channel := Limited(1, 0, 15);
    ActivateMidi(P);
    var Bank, ProgramNumber: Integer;
    P.LiveMidi.Synth.ChannelProgram(Channel, Bank, ProgramNumber);
    Exit(IntArray([Bank, ProgramNumber]));
  end;

  var Bank := 0;
  var ProgramNumber := 0;
  var Key := 0;
  if Name <> 'getBankList' then
    Bank := Limited(1, 0, 16383);
  if (Name = 'getProgramName') or (Name = 'getKeyName') then
    ProgramNumber := Limited(2, 0, 127);
  if Name = 'getKeyName' then
    Key := Limited(3, 0, 127);
  // Only device banks are available. MIDlets cannot install their own banks.
  if (Name = 'getBankList') and (Args[1].AsInt <> 0) then
    Exit(IntArray(nil));
  ActivateMidi(P);
  Synth := P.LiveMidi.Synth;
  if (Name = 'getBankList') or (Name = 'getProgramList') then
  begin
    var Numbers := TList<Integer>.Create;
    try
      for var Preset in Synth.Presets do
        if Name = 'getBankList' then
        begin
          if not Numbers.Contains(Preset.Bank) then
            Numbers.Add(Preset.Bank);
        end
        else if (Preset.Bank = Bank) and not Numbers.Contains(Preset.ProgramNumber) then
          Numbers.Add(Preset.ProgramNumber);
      Numbers.Sort;
      Exit(IntArray(Numbers.ToArray));
    finally
      Numbers.Free;
    end;
  end;
  for var Preset in Synth.Presets do
    if (Preset.Bank = Bank) and (Preset.ProgramNumber = ProgramNumber) then
    begin
      if Name = 'getProgramName' then
        Exit(TJVMValue.Ref(FVM.NewString(Preset.Name)));
      var KeyName: string;
      if Synth.TryGetKeyName(Bank, ProgramNumber, Key, KeyName) then
        Exit(TJVMValue.Ref(FVM.NewString(KeyName)));
      Exit(TJVMValue.Ref(0));
    end;
  FVM.RaiseJava(Media + 'MediaException', 'MIDI program is not installed');
end;

procedure TJ2MEMedia.RenderLiveMidi(P: TJ2MEMediaPlayer; var Mix: TArray<Int64>; Frames: Integer);
begin
  SetLength(FDecodeBuffer, Frames * 2);
  var Mixed := 0;
  var StopAt := StopPosition(P);
  while (Mixed < Frames) and (P.State = 400) do
  begin
    var EndPosition := PlaybackEndPosition(P, StopAt);
    var Boundary := Min(StopAt, EndPosition);
    var EndFrame := Boundary div 44100 + Ord(Boundary mod 44100 <> 0);
    var Count := Min(Frames - Mixed, 4096);
    if P.MidiTiming <> nil then
      Count := P.MidiTiming.RenderUntil(FDecodeBuffer, Count, EndFrame)
    else
    begin
      Count := Min(Int64(Count), Max(Int64(0), EndFrame - P.Position div 44100));
      Count := P.Decoder.Render(FDecodeBuffer, Count);
    end;
    if P.MidiTiming <> nil then
      P.Position := P.MidiTiming.PlaybackFrame * 44100
    else
      Inc(P.Position, Int64(Count) * 44100);
    if Count > 0 then
    begin
      if not P.Muted then
        for var I := 0 to Count * 2 - 1 do
          Inc(Mix[Mixed * 2 + I], Integer(FDecodeBuffer[I]) * P.Volume div 100);
      Inc(Mixed, Count);
    end;
    if (StopAt <> High(Int64)) and (P.Position >= StopAt) then
      StopAtTime(P)
    else if P.Position >= EndPosition then
    begin
      P.Position := EndPosition;
      EndOfMedia(P);
    end
    else if Count = 0 then
      raise EJVMError.Create('Unexpected end of live MIDI');
  end;
end;

function TJ2MEMedia.InvokeVodafoneSound(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  Data: TBytes;
  Track: TJVMObject;
  P: TJ2MEMediaPlayer;

  procedure Detach(Ref: Integer);
  begin
    if Ref = 0 then
      Exit;
    var Backing := Player(Ref);
    StopPlayer(Backing, False);
    Inc(Backing.Generation);
    Backing.State := 0;
    Backing.DiscardDecodedAudio;
    Backing.Data := nil;
  end;

  procedure LoadSound(PathRef: Integer);
  begin
    var Path := FVM.GetObject(PathRef).Text;
    if not TJavaHost(FVM.Host).LoadResource(Path, Data) then
      FVM.RaiseJava('java/io/IOException', 'Sound resource not found: ' + Path);
  end;

begin
  Result := Default(TJVMValue);
  var Name := Method.Name;
  if Method.Owner.Name = VodafoneSound then
  begin
    LoadSound(Args[1].AsRef);
    FVM.GetObject(Args[0].AsRef).Fields[VodafonePath] := Args[1];
    Exit;
  end;
  if Name = 'getPlayer' then
  begin
    var Instance := Method.Owner.Fields[0];
    if Instance.Value.AsRef = 0 then
      Instance.Value := TJVMValue.Ref(FVM.NewObject(VodafonePlayer));
    Exit(Instance.Value);
  end;
  if Name = 'getTrack' then
    Exit(TJVMValue.Ref(FVM.NewObject(VodafoneTrack)));

  if Name = 'disposeTrack' then
    Track := FVM.GetObject(Args[1].AsRef)
  else
    Track := FVM.GetObject(Args[0].AsRef);
  var Ref := Track.Fields[VodafoneBacking].AsRef;
  if Name = 'disposeTrack' then
  begin
    Detach(Ref);
    Track.Fields[VodafoneBacking] := TJVMValue.Ref(0);
    Track.Fields[VodafoneDisposed] := TJVMValue.Int(1);
    Exit;
  end;
  if Track.Fields[VodafoneDisposed].AsInt <> 0 then
    FVM.RaiseJava('java/lang/IllegalStateException', 'Sound track disposed');
  if Name = 'setSound' then
  begin
    var Sound := FVM.GetObject(Args[1].AsRef);
    LoadSound(Sound.Fields[VodafonePath].AsRef);
    var NewRef := CreatePlayer(Data, '');
    if J2MEVideoContentType(Player(NewRef).ContentType) then
    begin
      FPlayers.Remove(NewRef);
      FVM.RaiseJava('java/io/IOException', 'Sound track requires audio');
    end;
    Detach(Ref);
    Track.Fields[VodafoneBacking] := TJVMValue.Ref(NewRef);
  end
  else if Name = 'removeSound' then
  begin
    Detach(Ref);
    Track.Fields[VodafoneBacking] := TJVMValue.Ref(0);
  end
  else if Name = 'stop' then
  begin
    Track.Fields[VodafoneRequest] := TJVMValue.Int(Track.Fields[VodafoneRequest].AsInt + 1);
    if Ref <> 0 then
      StopPlayer(Player(Ref), False);
  end
  else if Name = '$prepare' then
  begin
    if Args[1].AsInt < 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Negative sound track loop count');
    if Ref = 0 then
      FVM.RaiseJava('java/lang/IllegalStateException', 'Sound track has no sound');
    Result := TJVMValue.Ref(Ref);
  end
  else if (Name = '$play') and (Ref = Args[1].AsRef) and
    (Track.Fields[VodafoneRequest].AsInt = Args[3].AsInt) then
  begin
    P := Player(Ref);
    StopPlayer(P, False);
    P.Position := 0;
    if P.LiveMidi <> nil then
      SelectAudioTrack(P.Decoder, 0)
    else if P.Streaming then
    begin
      P.Decoder := nil;
      P.PCM := nil;
      P.CacheFrame := 0;
      P.DecoderFrame := 0;
      P.SampleCount := 0;
    end;
    P.LoopCount := Args[2].AsInt;
    if P.LoopCount = 0 then
      P.LoopCount := -1;
    P.LoopsLeft := P.LoopCount;
    StartPlayer(P);
  end;
end;

function TJ2MEMedia.InvokeSamsungClip(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  Data: TBytes;

  procedure ResetClip(P: TJ2MEMediaPlayer);
  begin
    StopPlayer(P, False);
    P.Position := 0;
    if P.Streaming then
    begin
      P.Decoder := nil;
      P.PCM := nil;
      P.CacheFrame := 0;
      P.DecoderFrame := 0;
      P.SampleCount := 0;
    end;
  end;

begin
  Result := Default(TJVMValue);
  var Name := Method.Name;
  if Name = 'isSupported' then
    Exit(TJVMValue.Int(1));
  var Clip := FVM.GetObject(Args[0].AsRef);
  if Name = '<init>' then
  begin
    var ContentType: string;
    case Args[1].AsInt of
      1:
        ContentType := SMAFContentType;
      2:
        ContentType := MP3ContentType;
      3:
        ContentType := 'audio/midi';
    else
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Unsupported Samsung AudioClip type');
    end;
    if Args[2].AsRef = 0 then
      FVM.RaiseJava('java/lang/NullPointerException', 'Null AudioClip source');
    var Source := FVM.GetObject(Args[2].AsRef);
    if Method.Descriptor = '(ILjava/lang/String;)V' then
    begin
      var Path := Source.Text.Replace('\', '/');
      if not TJavaHost(FVM.Host).LoadResource(Path, Data) then
        FVM.RaiseJava('java/io/IOException', 'AudioClip resource not found: ' + Path);
    end
    else
    begin
      var Offset := Args[3].AsInt;
      var Count := Args[4].AsInt;
      if (Offset < 0) or (Count < 0) or (Offset > Source.ElementCount) or
        (Count > Source.ElementCount - Offset) then
        FVM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException', 'AudioClip data range');
      if Count > 16 * 1024 * 1024 then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'AudioClip too large');
      SetLength(Data, Count);
      for var I := 0 to Count - 1 do
        Data[I] := Byte(Source.ElementValues[Offset + I].AsInt);
    end;
    Clip.Fields[SamsungClipPlayer] := TJVMValue.Ref(CreatePlayer(Data, ContentType));
    Exit;
  end;
  if Name = '$validatePlay' then
  begin
    if not InRange(Args[1].AsInt, 0, 255) or not InRange(Args[2].AsInt, 0, 5) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'AudioClip loop or volume');
    Exit;
  end;
  var Ref := Clip.Fields[SamsungClipPlayer].AsRef;
  var Active: TJVMField := nil;
  var Paused: TJVMField := nil;
  for var Field in Method.Owner.Fields do
    if Field.Name = '$active' then
      Active := Field
    else if Field.Name = '$paused' then
      Paused := Field;
  if Name = '$play' then
  begin
    var P := Player(Ref);
    var Previous := Active.Value.AsRef;
    if (Previous <> 0) and (Previous <> Ref) then
      ResetClip(Player(Previous));
    StopPlayer(P, False);
    P.Position := 0;
    P.LoopCount := Args[1].AsInt;
    if P.LoopCount = 0 then
      P.LoopCount := -1;
    P.LoopsLeft := P.LoopCount;
    P.Volume := Args[2].AsInt * 20;
    Active.Value := TJVMValue.Ref(Ref);
    Paused.Value := TJVMValue.Int(0);
    StartPlayer(P);
    Exit;
  end;
  if (Ref = 0) or (Active.Value.AsRef <> Ref) then
    Exit;
  var P := Player(Ref);
  if Name = 'stop' then
  begin
    ResetClip(P);
    Active.Value := TJVMValue.Ref(0);
    Paused.Value := TJVMValue.Int(0);
  end
  else if (Name = 'pause') and (P.State = 400) then
  begin
    StopPlayer(P, False);
    Paused.Value := TJVMValue.Int(1);
  end
  else if (Name = 'resume') and (Paused.Value.AsInt <> 0) then
  begin
    Paused.Value := TJVMValue.Int(0);
    StartPlayer(P);
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
  if C = SamsungClip then
    Exit(InvokeSamsungClip(Method, Args));
  if (C = VodafoneSound) or (C = VodafonePlayer) or (C = VodafoneTrack) then
    Exit(InvokeVodafoneSound(Method, Args));
  if C = VideoControlImpl then
    Exit(InvokeVideoControl(N, Args));
  Result := Default(TJVMValue);
  if C = TimeBaseImpl then
    Exit(TJVMValue.Long(FVM.Host.MonotonicMillis * 1000));
  if (C = Manager) or (C = SiemensManager) then
  begin
    var Siemens := C = SiemensManager;
    var ErrorClass := Media + 'MediaException';
    if Siemens then
      ErrorClass := SiemensException;
    if N = '$stream' then
    begin
      if Args[0].AsRef = 0 then
        if Siemens then
          FVM.RaiseJava(ErrorClass, 'Null media stream')
        else
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
      Exit(TJVMValue.Ref(CreatePlayer(Data, Name, False, False, Siemens)));
    end;
    if N = 'createPlayer' then
    begin
      if Args[0].AsRef = 0 then
        if Siemens then
          FVM.RaiseJava(ErrorClass, 'Null media locator')
        else
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Null media locator');
      Name := FVM.GetObject(Args[0].AsRef).Text;
      if SameText(Name, ToneLocator) then
        Exit(TJVMValue.Ref(CreatePlayer(nil, J2METoneContentType, False, True, Siemens)));
      if SameText(Name, MIDILocator) then
        Exit(TJVMValue.Ref(CreatePlayer(nil, 'audio/midi', True, False, Siemens)));
      if LowerCase(Name).StartsWith('resource:') then
      begin
        var Path := Copy(Name, 10, MaxInt);
        while Path.StartsWith('//') do
          Delete(Path, 1, 1);
        if not TJavaHost(FVM.Host).LoadResource(Path, Data) then
          FVM.RaiseJava('java/io/IOException', 'Media resource not found: ' + Path);
        var Kind := '';
        if SameText(ExtractFileExt(Path), '.jts') then
          Kind := J2METoneContentType;
        Exit(TJVMValue.Ref(CreatePlayer(Data, Kind, False, False, Siemens)));
      end;
      if Siemens and (Pos(':', Name) = 0) then
      begin
        if not TJavaHost(FVM.Host).LoadResource(Name, Data) then
          FVM.RaiseJava('java/io/IOException', 'Media resource not found: ' + Name);
        Exit(TJVMValue.Ref(CreatePlayer(Data, '', False, False, True)));
      end;
      if (FFiles <> nil) and LowerCase(Name).StartsWith('file:') then
      begin
        Data := FFiles.ReadMedia(Name, Siemens);
        Exit(TJVMValue.Ref(CreatePlayer(Data, '', False, False, Siemens)));
      end;
      FVM.RaiseJava(ErrorClass, 'Unsupported media locator: ' + Name);
    end;
    if N = 'getSupportedContentTypes' then
    begin
      if Args[0].AsRef <> 0 then
      begin
        Name := FVM.GetObject(Args[0].AsRef).Text;
        if Name = 'device' then
        begin
          if Siemens then
            Exit(Strings(['audio/x-mid', J2METoneContentType]));
          Exit(Strings(['audio/midi', J2METoneContentType]));
        end;
        if (Name <> 'resource') and ((Name <> 'file') or (FFiles = nil)) then
          Exit(Strings([]));
      end;
      var Types: TArray<string>;
      if Siemens then
        Types := ['audio/x-wav', 'audio/x-mid', J2METoneContentType, SiemensSMAFContentType, MP3ContentType]
      else
        Types := ['audio/x-wav', 'audio/midi', J2METoneContentType, SMAFContentType, MP3ContentType];
      Types := Types + [IMelodyContentType, AMRNarrowbandContentType, AMRWidebandContentType];
      if not Siemens then
        Types := Types + [MP4AudioContentType, ThreeGPAudioContentType, 'video/mp4', 'video/3gpp', 'video/mpeg4-generic'];
      Exit(Strings(Types));
    end;
    if N = 'getSupportedProtocols' then
    begin
      if Args[0].AsRef <> 0 then
      begin
        Name := LowerCase(FVM.GetObject(Args[0].AsRef).Text);
        if (Name = 'audio/x-wav') or (Name = SMAFContentType) or (Name = SiemensSMAFContentType) or
          IsMP3ContentType(Name) or IsAMRContentType(Name) or IsIMelodyContentType(Name) or
          (not Siemens and (J2MEVideoContentType(Name) or J2MEContainerAudioType(Name))) then
        begin
          if FFiles <> nil then
            Exit(Strings(['resource', 'file']));
          Exit(Strings(['resource']));
        end;
        if (Name <> 'audio/midi') and (Name <> 'audio/x-mid') and (Name <> J2METoneContentType) then
          Exit(Strings([]));
      end;
      if FFiles <> nil then
        Exit(Strings(['resource', 'device', 'file']));
      Exit(Strings(['resource', 'device']));
    end;
    if N = 'getSystemTimeBase' then
      Exit(TJVMValue.Ref(FTimeBase));
    if N = 'playTone' then
    begin
      if (Args[0].AsInt < 0) or (Args[0].AsInt > 127) or (Args[1].AsInt <= 0) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Tone note/duration');
      if FTones.Count >= 64 then
        FVM.RaiseJava(ErrorClass, 'Tone voice limit');
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
  begin
    var Fields := FVM.GetObject(Ref).Fields;
    if not Fields.TryGetValue(SiemensControlPlayerKey, Value) then
      Value := Fields[VolumeImpl + '.$player:' + PlayerDesc];
    Ref := Value.AsRef;
  end;
  if C = ToneImpl then
  begin
    var Fields := FVM.GetObject(Ref).Fields;
    if not Fields.TryGetValue(SiemensControlPlayerKey, Value) then
      Value := Fields[ToneImpl + '.$player:' + PlayerDesc];
    Ref := Value.AsRef;
    SetToneSequence(Player(Ref), Args[1]);
    Exit;
  end;
  if C = MIDIImpl then
  begin
    Ref := FVM.GetObject(Ref).Fields[MIDIImpl + '.$player:' + PlayerDesc].AsRef;
    Exit(InvokeMIDIControl(Player(Ref), N, Args));
  end;
  if C = TempoImpl then
  begin
    Ref := FVM.GetObject(Ref).Fields[TempoImpl + '.$player:' + PlayerDesc].AsRef;
    Exit(InvokeTempoControl(Player(Ref), N, Args));
  end;
  if C = MetadataImpl then
  begin
    Ref := FVM.GetObject(Ref).Fields[MetadataImpl + '.$player:' + PlayerDesc].AsRef;
    Exit(InvokeMetadataControl(Player(Ref), N, Args));
  end;
  if C = StopTimeImpl then
  begin
    Ref := FVM.GetObject(Ref).Fields[StopTimeImpl + '.$player:' + PlayerDesc].AsRef;
    P := Player(Ref);
    if N = 'getStopTime' then
      Exit(TJVMValue.Long(GetStopTime(P)));
    if (P.State = 400) and (GetStopTime(P) <> StopTimeReset) then
      FVM.RaiseJava('java/lang/IllegalStateException', 'Stop time is already set');
    var Time := Args[1].AsLong;
    var Fields := FVM.GetObject(Ref).Fields;
    if Time = StopTimeReset then
      Fields.Remove(StopTimeKey)
    else
    begin
      Fields.AddOrSetValue(StopTimeKey, TJVMValue.Long(Time));
      CheckStopTime(P);
    end;
    Exit;
  end;
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
    begin
      if P.MidiDevice then
        ActivateMidi(P);
      P.State := 300;
    end;
    Exit;
  end;
  if N = '$start' then
  begin
    StartPlayer(P);
    Exit;
  end;
  if (N = 'stop') or (N = 'deallocate') or (N = 'close') then
  begin
    if (N = 'close') and (P.State = 0) then
      Exit;
    StopPlayer(P, N <> 'close');
    if N = 'deallocate' then
    begin
      if P.Decoding then
      begin
        Inc(P.Generation);
        P.DiscardDecodedAudio;
      end;
      if P.State >= 300 then
        P.State := 200;
      if P.Video <> nil then
      begin
        P.Video.Reset;
        FVideoDirty := True;
      end;
      if (P.LiveMidi <> nil) and (P.MidiTiming = nil) then
      begin
        P.LiveMidi := nil;
        P.Decoder := nil;
        P.MidiStatus := 0;
        P.MidiPendingCount := 0;
      end;
      if P.Streaming and (P.MidiTiming = nil) then
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
      if P.Video <> nil then
      begin
        var VideoControl := VideoControlFor(P);
        if VideoControl <> nil then
        begin
          var Item := LCDRef(VideoControl, 'videoItem');
          if Item <> 0 then
          begin
            LCDPutRef(FVM.GetObject(Item), 'videoControl', 0);
            LCDPutRef(VideoControl, 'videoItem', 0);
          end;
        end;
        FreeAndNil(P.Video);
        FVM.GetObject(Ref).Fields.Remove(VideoControlKey);
        FVideoDirty := True;
      end;
      P.DiscardDecodedAudio;
      P.MidiDevice := False;
      P.Data := nil;
      FVM.GetObject(Ref).Fields.Remove(RestartTempoKey);
      PostEvent(P, 'closed', 0);
      FVM.GetObject(Ref).Fields[ListenerField(P.Reference)] := TJVMValue.Ref(0);
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
  begin
    Name := P.ContentType;
    if C = SiemensPlayerImpl then
    begin
      if Name = 'audio/midi' then
        Name := 'audio/x-mid'
      else if Name = SMAFContentType then
        Name := SiemensSMAFContentType;
    end;
    Exit(TJVMValue.Ref(FVM.NewString(Name)));
  end;
  if N = 'setMediaTime' then
  begin
    if P.MidiDevice then
      FVM.RaiseJava(MediaErrorClass(P.Reference), 'The MIDI device has no sequence to seek');
    var Time := EnsureRange(Args[1].AsLong, Int64(0), P.Duration);
    if P.Video <> nil then
    begin
      SeekVideo(P, Time);
      Exit(TJVMValue.Long(P.MediaTime));
    end;
    P.Position := (Time * P.Info.SampleRate div 1000000) * 44100;
    if Time = P.Duration then
      P.Position := P.FrameCount * 44100;
    if P.LiveMidi <> nil then
    begin
      // A seek rebuilds the file's channel and note state at the destination.
      SelectAudioTrack(P.Decoder, 0);
      var Seeker := P.Decoder as IAudioSeekSource;
      Seeker.SeekFrame(P.Position div 44100,
        function: Boolean
        begin
          Result := FVM.StopRequested or J2MEAudioThreadTerminated;
        end);
    end;
    FVM.GetObject(P.Reference).Fields.Remove(RestartTempoKey);
    CheckStopTime(P);
    Exit(TJVMValue.Long(P.MediaTime));
  end;
  if N = 'getControl' then
  begin
    if Args[1].AsRef = 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Null control type');
    Name := FVM.GetObject(Args[1].AsRef).Text;
    if P.Video <> nil then
    begin
      if (Name = 'VideoControl') or (Name = VideoControlAPI.Replace('/', '.')) or
        (Name = 'GUIControl') or (Name = GUIControlAPI.Replace('/', '.')) or
        (Name = 'DisplayModeControl') or (Name = DisplayModeAPI.Replace('/', '.')) or
        (Name = 'FramePositioningControl') or (Name = FramePositioningAPI.Replace('/', '.')) then
        Exit(VideoControlRef(P));
      if (Name = 'StopTimeControl') or (Name = StopTimeAPI.Replace('/', '.')) then
        Exit(StopTimeControlRef(P));
      if P.Video.HasAudio and ((Name = 'VolumeControl') or (Name = VolumeAPI.Replace('/', '.'))) then
        Exit(FVM.GetObject(Ref).Fields[C + '.$volume:' + VolumeDesc]);
      Exit(TJVMValue.Ref(0));
    end;
    if (Name = 'VolumeControl') or (Name = VolumeAPI.Replace('/', '.')) or
      ((C = SiemensPlayerImpl) and (Name = SiemensVolume.Replace('/', '.'))) then
      Exit(FVM.GetObject(Ref).Fields[C + '.$volume:' + VolumeDesc]);
    if (Name = 'ToneControl') or (Name = ToneAPI.Replace('/', '.')) or
      ((C = SiemensPlayerImpl) and (Name = SiemensTone.Replace('/', '.'))) then
      Exit(ToneControlRef(P));
    if C = SiemensPlayerImpl then
      Exit(TJVMValue.Ref(0));
    if (Name = 'StopTimeControl') or (Name = StopTimeAPI.Replace('/', '.')) then
      Exit(StopTimeControlRef(P));
    if (Name = 'MetaDataControl') or (Name = MetadataAPI.Replace('/', '.')) then
      Exit(MetadataControlRef(P));
    if (Name = 'MIDIControl') or (Name = MIDIAPI.Replace('/', '.')) then
      Exit(MIDIControlRef(P));
    if (Name = 'TempoControl') or (Name = 'RateControl') or
      (Name = TempoAPI.Replace('/', '.')) or (Name = RateAPI.Replace('/', '.')) then
      Exit(TempoControlRef(P));
    Exit(TJVMValue.Ref(0));
  end;
  if N = 'getControls' then
  begin
    if P.Video <> nil then
    begin
      var VideoControl := VideoControlRef(P);
      var StopControl := StopTimeControlRef(P);
      ArrayRef := FVM.NewArray('[Ljavax/microedition/media/Control;', 2 + Ord(P.Video.HasAudio));
      FVM.GetObject(ArrayRef).ElementValues[0] := VideoControl;
      FVM.GetObject(ArrayRef).ElementValues[1] := StopControl;
      if P.Video.HasAudio then
        FVM.GetObject(ArrayRef).ElementValues[2] := FVM.GetObject(Ref).Fields[C + '.$volume:' + VolumeDesc];
      Exit(TJVMValue.Ref(ArrayRef));
    end;
    if C = SiemensPlayerImpl then
    begin
      var Tone := ToneControlRef(P);
      ArrayRef := FVM.NewArray('[' + SiemensControlDesc, 1 + Ord(Tone.AsRef <> 0));
      FVM.GetObject(ArrayRef).ElementValues[0] := FVM.GetObject(Ref).Fields[C + '.$volume:' + VolumeDesc];
      if Tone.AsRef <> 0 then
        FVM.GetObject(ArrayRef).ElementValues[1] := Tone;
      Exit(TJVMValue.Ref(ArrayRef));
    end;
    var MIDI := MIDIControlRef(P);
    var Tempo := TempoControlRef(P);
    var Tone := ToneControlRef(P);
    var StopTime := StopTimeControlRef(P);
    var Metadata := MetadataControlRef(P);
    var Count := 2 + Ord(MIDI.AsRef <> 0) + Ord(Tempo.AsRef <> 0) +
      Ord(Tone.AsRef <> 0) + Ord(Metadata.AsRef <> 0);
    ArrayRef := FVM.NewArray('[Ljavax/microedition/media/Control;', Count);
    FVM.GetObject(ArrayRef).ElementValues[0] := FVM.GetObject(Ref).Fields[PlayerImpl + '.$volume:' + VolumeDesc];
    if MIDI.AsRef <> 0 then
      FVM.GetObject(ArrayRef).ElementValues[1] := MIDI;
    if Tempo.AsRef <> 0 then
      FVM.GetObject(ArrayRef).ElementValues[2] := Tempo;
    if Tone.AsRef <> 0 then
      FVM.GetObject(ArrayRef).ElementValues[1] := Tone;
    if Metadata.AsRef <> 0 then
      FVM.GetObject(ArrayRef).ElementValues[Count - 2] := Metadata;
    FVM.GetObject(ArrayRef).ElementValues[Count - 1] := StopTime;
    Exit(TJVMValue.Ref(ArrayRef));
  end;
  if (N = 'getTimeBase') or (N = 'setTimeBase') then
  begin
    if (P.State < 200) or ((N = 'setTimeBase') and (P.State = 400)) then
      FVM.RaiseJava('java/lang/IllegalStateException', 'Time base is unavailable in the current player state');
    if N = 'getTimeBase' then
      Exit(TJVMValue.Ref(FTimeBase));
    if (Args[1].AsRef <> 0) and (Args[1].AsRef <> FTimeBase) then
      FVM.RaiseJava(MediaErrorClass(P.Reference), 'Player supports only the system time base');
    Exit;
  end;
  if (N = 'addPlayerListener') or (N = 'removePlayerListener') then
  begin
    Ref := Args[1].AsRef;
    if Ref = 0 then
      Exit;
    A := nil;
    Index := -1;
    Value := FVM.GetObject(P.Reference).Fields[ListenerField(P.Reference)];
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
      FVM.RaiseJava(MediaErrorClass(P.Reference), 'Listener limit');
    ArrayRef := FVM.NewArray(ListenerArray(P.Reference), V + IfThen(Adding, 1, -1));
    var J := 0;
    for var I := 0 to V - 1 do
      if Adding or (I <> Index) then
      begin
        FVM.GetObject(ArrayRef).ElementValues[J] := A.ElementValues[I];
        Inc(J);
      end;
    if Adding then
      FVM.GetObject(ArrayRef).ElementValues[J] := TJVMValue.Ref(Ref);
    FVM.GetObject(P.Reference).Fields[ListenerField(P.Reference)] := TJVMValue.Ref(ArrayRef);
    Exit;
  end;
  raise EJVMUnsupported.Create('Unimplemented media native ' + C + '.' + N);
end;

procedure TJ2MEMedia.OpenVideo(P: TJ2MEMediaPlayer);
begin
  var Count := 0;
  for var Other in FPlayers.Values do
    if Other.Video <> nil then
      Inc(Count);
  if Count >= VideoLimit then
    raise EArgumentException.Create('Realized video player limit');
  P.Video := TJ2MEVideoStream.Create(P.Data);
end;

procedure TJ2MEMedia.SeekVideo(P: TJ2MEMediaPlayer; Time: Int64);
begin
  P.Position := Time * 44100;
  P.Video.Reset;
  FVideoDirty := True;
  CheckStopTime(P);
end;

function TJ2MEMedia.VideoControlRef(P: TJ2MEMediaPlayer): TJVMValue;
begin
  var Fields := FVM.GetObject(P.Reference).Fields;
  if not Fields.TryGetValue(VideoControlKey, Result) then
  begin
    Result := TJVMValue.Ref(FVM.NewObject(VideoControlImpl));
    FVM.GetObject(Result.AsRef).Fields[VideoControlImpl + '.$player:' + PlayerDesc] := TJVMValue.Ref(P.Reference);
    Fields.Add(VideoControlKey, Result);
  end;
end;

function TJ2MEMedia.VideoControlFor(P: TJ2MEMediaPlayer): TJVMObject;
begin
  Result := nil;
  var Control: TJVMValue;
  if FVM.GetObject(P.Reference).Fields.TryGetValue(VideoControlKey, Control) and (Control.AsRef <> 0) then
    Result := FVM.GetObject(Control.AsRef);
end;

procedure TJ2MEMedia.VideoGeometry(Control: TJVMObject; P: TJ2MEMediaPlayer; out X, Y, W, H: Integer);
begin
  X := LCDInt(Control, 'videoX');
  Y := LCDInt(Control, 'videoY');
  var OrientedWidth := P.Video.Info.Width;
  var OrientedHeight := P.Video.Info.Height;
  if LCDInt(Control, 'videoTransform') >= 4 then
  begin
    OrientedWidth := P.Video.Info.Height;
    OrientedHeight := P.Video.Info.Width;
  end;
  W := LCDInt(Control, 'videoWidth', OrientedWidth);
  H := LCDInt(Control, 'videoHeight', OrientedHeight);
  if (LCDInt(Control, 'videoFullscreen') <> 0) and Assigned(FVideoBounds) then
  begin
    var Canvas := LCDRef(Control, 'videoCanvas');
    var Display := Canvas;
    var Item := LCDRef(Control, 'videoItem');
    if Item <> 0 then
      Display := LCDRef(FVM.GetObject(Item), 'owner');
    if Display = 0 then
      Exit;
    var Bounds := FVideoBounds(Display);
    W := Max(1, Bounds.Width);
    H := Max(1, W * OrientedHeight div OrientedWidth);
    if H > Bounds.Height then
    begin
      H := Max(1, Bounds.Height);
      W := Max(1, H * OrientedWidth div OrientedHeight);
    end;
    if Canvas <> 0 then
    begin
      X := (Bounds.Width - W) div 2;
      Y := (Bounds.Height - H) div 2;
    end;
  end;
end;

function TJ2MEMedia.SyncVideoItem(Control: TJVMObject; P: TJ2MEMediaPlayer): Boolean;
begin
  Result := False;
  var Ref := LCDRef(Control, 'videoItem');
  if Ref = 0 then
    Exit;
  var Item := FVM.GetObject(Ref);
  var X, Y, W, H: Integer;
  VideoGeometry(Control, P, X, Y, W, H);
  W := Min(W, 1048576);
  H := Min(H, 1048576);
  if (LCDInt(Item, 'videoWidth') = W) and (LCDInt(Item, 'videoHeight') = H) then
    Exit;
  LCDPut(Item, 'videoWidth', W);
  LCDPut(Item, 'videoHeight', H);
  UIInvalidateOwner(FVM, Item);
  Result := True;
end;

function TJ2MEMedia.VideoSnapshot(P: TJ2MEMediaPlayer; Control: TJVMObject; Param: Integer): TJVMValue;
begin
  var ErrorClass := MediaErrorClass(P.Reference);
  var Encoding := 'jpeg';
  var Width := 0;
  var Height := 0;
  var Quality := 85;
  if Param <> 0 then
  begin
    var Spec := FVM.GetObject(Param).Text.Trim.ToLowerInvariant;
    var Seen: set of  (CodecOption, WidthOption, HeightOption, QualityOption) := [];
    for var Pair in Spec.Split(['&']) do
    begin
      var Split := Pos('=', Pair);
      var Key := Copy(Pair, 1, Split - 1);
      var Value := Copy(Pair, Split + 1, MaxInt);
      var Number: Integer;
      if (Key = 'encoding') and not (CodecOption in Seen) then
      begin
        Encoding := Value;
        Include(Seen, CodecOption);
      end
      else if (Key = 'width') and not (WidthOption in Seen) and TryStrToInt(Value, Number) and
        (Number >= 1) and (Number <= 1024) then
      begin
        Width := Number;
        Include(Seen, WidthOption);
      end
      else if (Key = 'height') and not (HeightOption in Seen) and TryStrToInt(Value, Number) and
        (Number >= 1) and (Number <= 1024) then
      begin
        Height := Number;
        Include(Seen, HeightOption);
      end
      else if (Key = 'quality') and not (QualityOption in Seen) and TryStrToInt(Value, Number) and
        (Number >= 1) and (Number <= 100) then
      begin
        Quality := Number;
        Include(Seen, QualityOption);
      end
      else
        FVM.RaiseJava(ErrorClass, 'Unsupported video snapshot parameter: ' + Pair);
    end;
    if (QualityOption in Seen) and (Encoding = 'png') then
      FVM.RaiseJava(ErrorClass, 'Video snapshot quality applies to JPEG');
  end;
  if Encoding = 'jpg' then
    Encoding := 'jpeg';
  if (Encoding <> 'jpeg') and (Encoding <> 'png') then
    FVM.RaiseJava(ErrorClass, 'Unsupported video snapshot encoding: ' + Encoding);
  var Time := P.MediaTime;
  if Time < P.Video.FrameToTime(0) then
    FVM.RaiseJava(ErrorClass, 'No video frame at the current media time');
  var Data: TBytes;
  try
    if P.Video.Advance(Time) then
      FVideoDirty := True;
    if P.Video.SnapshotReady(Time) then
      Data := P.Video.EncodeSnapshot(Encoding, Width, Height, Quality, LCDInt(Control, 'videoTransform'));
  except
    on E: Exception do
      FVM.RaiseJava(ErrorClass, E.Message);
  end;
  if Length(Data) = 0 then
  begin
    var Attempt := FVM.NativeContinuation;
    var Count := 0;
    if Attempt.Kind = TJVMKind.Int then
      Count := Attempt.AsInt;
    if Count >= 256 then
      FVM.RaiseJava(ErrorClass, 'Video frame could not be decoded for snapshot');
    FVM.SetNativeContinuation(TJVMValue.Int(Count + 1));
    FVM.YieldCurrent;
    FVM.RetryNative;
  end;
  if Length(Data) > FVM.MaxArrayLength then
    FVM.RaiseJava(ErrorClass, 'Video snapshot exceeds Java array limit');
  var Ref := FVM.NewArray('[B', Length(Data));
  var Bytes := FVM.GetObject(Ref);
  for var I := 0 to High(Data) do
    Bytes.ElementValues[I] := TJVMValue.Int(ShortInt(Data[I]));
  Result := TJVMValue.Ref(Ref);
end;

function TJ2MEMedia.InvokeVideoControl(const Name: string; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := FVM.GetObject(Args[0].AsRef);
  var P := Player(O.Fields[VideoControlImpl + '.$player:' + PlayerDesc].AsRef);
  if Name = 'mapFrameToTime' then
    Exit(TJVMValue.Long(P.Video.FrameToTime(Args[1].AsInt)));
  if Name = 'mapTimeToFrame' then
    Exit(TJVMValue.Int(P.Video.TimeToFrame(Args[1].AsLong)));
  if (Name = 'seek') or (Name = 'skip') then
  begin
    var Current := Max(0, P.Video.TimeToFrame(P.MediaTime));
    var Target := Int64(Args[1].AsInt);
    if Name = 'skip' then
    begin
      if Target = 0 then
        Exit(TJVMValue.Int(0));
      Inc(Target, Current);
    end;
    var Frame := Integer(EnsureRange(Target, Int64(0), P.Video.FrameCount - 1));
    SeekVideo(P, P.Video.FrameToTime(Frame));
    if Name = 'skip' then
      Dec(Frame, Current);
    Exit(TJVMValue.Int(Frame));
  end;
  if Name = 'getSourceWidth' then
    Exit(TJVMValue.Int(P.Video.Info.Width));
  if Name = 'getSourceHeight' then
    Exit(TJVMValue.Int(P.Video.Info.Height));
  var Canvas := LCDRef(O, 'videoCanvas');
  var Item := LCDRef(O, 'videoItem');
  if Name = 'initDisplayMode' then
  begin
    if (Canvas <> 0) or (Item <> 0) then
      FVM.RaiseJava('java/lang/IllegalStateException', 'Video display already initialized');
    var Target := Args[2].AsRef;
    var Mode := Args[1].AsInt;
    if Mode = UseGUIPrimitive then
    begin
      if Target <> 0 then
      begin
        var TypeName := FVM.GetObject(Target);
        if (TypeName.ClassName <> 'java/lang/String') or (TypeName.Text <> 'javax.microedition.lcdui.Item') then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Video GUI primitive requires an LCDUI Item');
      end;
      Item := FVM.NewObject(VideoItemClass);
      var VideoItem := FVM.GetObject(Item);
      UIInitItem(VideoItem, 0);
      LCDPut(VideoItem, 'itemKind', J2MEVideoItemKind);
      LCDPutRef(VideoItem, 'videoControl', Args[0].AsRef);
      LCDPutRef(O, 'videoItem', Item);
      LCDPut(O, 'videoVisible', 1);
      SyncVideoItem(O, P);
      Exit(TJVMValue.Ref(Item));
    end;
    if ((Mode and not VideoTransformMask) <> UseDirectVideo) or (Target = 0) or
      not FVM.IsAssignable(FVM.GetObject(Target).ClassName, 'javax/microedition/lcdui/Canvas') then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Video display requires USE_DIRECT_VIDEO and a Canvas');
    // Sony Ericsson encodes the MIDP Sprite orientation in bits 4..6.
    LCDPutRef(O, 'videoCanvas', Target);
    LCDPut(O, 'videoTransform', (Mode and VideoTransformMask) shr VideoTransformShift);
    Exit(TJVMValue.Ref(0));
  end;
  if (Canvas = 0) and (Item = 0) then
    FVM.RaiseJava('java/lang/IllegalStateException', 'Video display is not initialized');
  if Name = 'getSnapshot' then
    Exit(VideoSnapshot(P, O, Args[1].AsRef));
  if Name = 'getDisplayMode' then
    Exit(TJVMValue.Int(LCDInt(O, 'videoTransform') shl VideoTransformShift));
  if Name = 'setDisplayMode' then
  begin
    var Mode := Args[1].AsInt;
    if (Canvas = 0) or ((Mode and not VideoTransformMask) <> 0) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid video orientation');
    LCDPut(O, 'videoTransform', Mode shr VideoTransformShift);
    FVideoDirty := True;
    Exit;
  end;
  if Name.StartsWith('getDisplay') then
  begin
    var X, Y, W, H: Integer;
    VideoGeometry(O, P, X, Y, W, H);
    if Name = 'getDisplayX' then
      Exit(TJVMValue.Int(X));
    if Name = 'getDisplayY' then
      Exit(TJVMValue.Int(Y));
    if Name = 'getDisplayWidth' then
      Exit(TJVMValue.Int(W));
    Exit(TJVMValue.Int(H));
  end;
  if Name = 'setDisplayLocation' then
  begin
    if Canvas = 0 then
      Exit;
    LCDPut(O, 'videoX', Args[1].AsInt);
    LCDPut(O, 'videoY', Args[2].AsInt);
  end
  else if Name = 'setDisplaySize' then
  begin
    if (Args[1].AsInt <= 0) or (Args[2].AsInt <= 0) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid video display dimensions');
    LCDPut(O, 'videoWidth', Args[1].AsInt);
    LCDPut(O, 'videoHeight', Args[2].AsInt);
  end
  else if Name = 'setDisplayFullScreen' then
    LCDPut(O, 'videoFullscreen', Ord(Args[1].AsInt <> 0))
  else if Name = 'setVisible' then
    LCDPut(O, 'videoVisible', Ord(Args[1].AsInt <> 0));
  if Item <> 0 then
    SyncVideoItem(O, P);
  FVideoDirty := True;
end;

procedure TJ2MEMedia.AdvanceVideoClock(P: TJ2MEMediaPlayer; Frames: Integer; var Mix: TArray<Int64>);
begin
  var Offset := 0;
  var Level := P.Volume;
  if P.Muted then
    Level := 0;
  while (Frames > 0) and (P.State = 400) do
  begin
    var StopAt := StopPosition(P);
    var Finish := P.FrameCount * 44100;
    var Boundary := Min(StopAt, Finish);
    var Distance := Max(Int64(0), Boundary - P.Position);
    var Step := Integer(Min(Int64(Frames), (Distance + VideoClockRate - 1) div VideoClockRate));
    P.Video.MixAudio(P.Position, Offset, Step, Level, Mix,
      function: Boolean
      begin
        Result := FVM.StopRequested or J2MEAudioThreadTerminated;
      end);
    Inc(Offset, Step);
    Inc(P.Position, Min(Distance, Int64(Step) * VideoClockRate));
    Dec(Frames, Step);
    if P.Position >= Boundary then
      if StopAt <= Finish then
        StopAtTime(P)
      else
      begin
        EndOfMedia(P);
        if P.State = 400 then
        begin
          P.Video.Reset;
          FVideoDirty := True;
        end;
      end;
  end;
end;

procedure TJ2MEMedia.VideoError(P: TJ2MEMediaPlayer; const MessageText: string);
begin
  StopPlayer(P, False);
  P.State := 200;
  P.Video.Reset;
  FVideoDirty := True;
  PostEvent(P, 'error', FVM.NewString(MessageText));
end;

function TJ2MEMedia.UpdateVideo(Screen: Integer): Boolean;
begin
  Sweep;
  Result := FVideoDirty;
  FVideoDirty := False;
  if Screen = 0 then
    Exit;
  for var P in FPlayers.Values do
    if P.Video <> nil then
    begin
      var Control := VideoControlFor(P);
      if Control = nil then
        Continue;
      var Display := LCDRef(Control, 'videoCanvas');
      var Item := LCDRef(Control, 'videoItem');
      if Item <> 0 then
      begin
        Display := LCDRef(FVM.GetObject(Item), 'owner');
        if (Display = Screen) and SyncVideoItem(Control, P) then
          Result := True;
      end;
      if (Display <> Screen) or (P.State < 300) or (LCDInt(Control, 'videoVisible') = 0) then
        Continue;
      try
        if P.Video.Advance(P.MediaTime) then
          Result := True;
      except
        on E: Exception do
        begin
          VideoError(P, E.Message);
          Result := True;
        end;
      end;
    end;
end;

procedure TJ2MEMedia.DrawVideo(Screen: Integer; var Pixels: TArray<UInt32>; Width, Height: Integer);
begin
  if (Screen = 0) or not Assigned(FVideoBounds) then
    Exit;
  var Keys := FPlayers.Keys.ToArray;
  TArray.Sort<Integer>(Keys);
  var Bounds := FVideoBounds(Screen);
  for var Key in Keys do
  begin
    var P := FPlayers[Key];
    if (P.Video = nil) or (P.State < 300) then
      Continue;
    var Control := VideoControlFor(P);
    if (Control = nil) or (LCDRef(Control, 'videoCanvas') <> Screen) or (LCDInt(Control, 'videoVisible') = 0) then
      Continue;
    var X, Y, W, H: Integer;
    VideoGeometry(Control, P, X, Y, W, H);
    if (Y >= Bounds.Height) or (Int64(Y) + H <= 0) then
      Continue;
    P.Video.Draw(Pixels, Width, X, Y + Bounds.Top, W, H, LCDInt(Control, 'videoTransform'),
      Rect(0, Bounds.Top, Width, Min(Height, Bounds.Bottom)));
  end;
end;

procedure TJ2MEMedia.DrawVideoItem(Item: Integer; var Pixels: TArray<UInt32>; Stride, X, Y: Integer; const Clip: TRect);
begin
  var Ref := LCDRef(FVM.GetObject(Item), 'videoControl');
  if Ref = 0 then
    Exit;
  var Control := FVM.GetObject(Ref);
  if LCDInt(Control, 'videoVisible') = 0 then
    Exit;
  var PlayerRef := Control.Fields[VideoControlImpl + '.$player:' + PlayerDesc].AsRef;
  var P: TJ2MEMediaPlayer;
  if not FPlayers.TryGetValue(PlayerRef, P) or (P.Video = nil) or (P.State < 300) then
    Exit;
  var VideoX, VideoY, W, H: Integer;
  VideoGeometry(Control, P, VideoX, VideoY, W, H);
  P.Video.Draw(Pixels, Stride, X, Y, W, H, 0, Clip);
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
      if P.Video <> nil then
      begin
        try
          AdvanceVideoClock(P, Frames, Mix);
        except
          on E: EAbort do
            raise;
          on E: Exception do
            VideoError(P, E.Message);
        end;
        Continue;
      end;
      if P.LiveMidi <> nil then
      begin
        RenderLiveMidi(P, Mix, Frames);
        Continue;
      end;
      var StopAt := StopPosition(P);
      var EndPosition := PlaybackEndPosition(P, StopAt);
      var Boundary := Min(StopAt, EndPosition);
      for var I := 0 to Frames - 1 do
      begin
        if P.State <> 400 then
          Break;
        if P.Position >= EndPosition then
        begin
          EndOfMedia(P);
          if P.State <> 400 then
            Break;
          EndPosition := PlaybackEndPosition(P, StopAt);
          Boundary := Min(StopAt, EndPosition);
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
        if P.Position >= Boundary then
        begin
          P.Position := Min(P.Position, EndPosition);
          if P.Position >= StopAt then
            StopAtTime(P)
          else
          begin
            EndOfMedia(P);
            EndPosition := PlaybackEndPosition(P, StopAt);
            Boundary := Min(StopAt, EndPosition);
          end;
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
    begin
      if P.MidiTiming <> nil then
      begin
        Tag := 'J2ME.Media-4';
        Break;
      end;
      if P.MidiDevice or (P.LiveMidi <> nil) then
        Tag := 'J2ME.Media-3'
      else if (P.Streaming or (P.Video <> nil)) and (Tag = 'J2ME.Media-1') then
        Tag := 'J2ME.Media-2';
    end;
  S.Text(Tag);
  var Version4 := Tag = 'J2ME.Media-4';
  var Version3 := Version4 or (Tag = 'J2ME.Media-3');
  if not Version3 and (Tag <> 'J2ME.Media-1') and (Tag <> 'J2ME.Media-2') then
    raise EReadError.Create('Unsupported media snapshot version');
  var Version2 := Tag <> 'J2ME.Media-1';
  if S.Loading then
  begin
    // Older class layouts lack these fields. Bind the literals to the restored heap.
    for var Field in FVM.LoadClass(Manager).Fields do
      if Field.Name = 'MIDI_DEVICE_LOCATOR' then
        Field.Value := TJVMValue.Ref(FVM.InternString(MIDILocator));
    for var Field in FVM.LoadClass(Listener).Fields do
      if Field.Name = 'STOPPED_AT_TIME' then
        Field.Value := TJVMValue.Ref(FVM.InternString(StoppedAtTime));
    for var Field in FVM.LoadClass(SiemensManager).Fields do
      if Field.Name = 'MIDI_DEVICE_LOCATOR' then
        Field.Value := TJVMValue.Ref(FVM.InternString(MIDILocator))
      else if Field.Name = 'TONE_DEVICE_LOCATOR' then
        Field.Value := TJVMValue.Ref(FVM.InternString(ToneLocator));
    for var Field in FVM.LoadClass(SiemensListener).Fields do
      Field.Value := TJVMValue.Ref(FVM.InternString(MediaEventLiteral(Field.Name)));
  end;
  // Older snapshots stored rendered frames here. The runtime now supplies
  // both the current monotonic time and its restored value.
  var LegacyClockFrames: Int64 := 0;
  S.Int64Value(LegacyClockFrames);
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
      var Live := P.LiveMidi <> nil;
      if Version3 then
      begin
        S.Bool(P.MidiDevice);
        S.Bool(Live);
        if Live then
        begin
          var Timed := P.MidiTiming <> nil;
          if Version4 then
            S.Bool(Timed);
          if (P.ContentType <> 'audio/midi') or (P.State < 200) or
            ((P.State < 300) and not Timed) or (Timed and P.MidiDevice) or P.Decoding or
            (P.Info.SampleRate <> 44100) or (P.Info.Channels <> 2) or
            (P.Position < 0) or (P.Position mod 44100 <> 0) then
            raise EReadError.Create('Invalid live MIDI snapshot');
          if S.Loading then
            ActivateMidi(P, True);
          TransferJ2MEMidiSynth(S, P.LiveMidi.Synth);
          S.Int(P.MidiStatus);
          S.Count(P.MidiPendingCount, Length(P.MidiPending));
          for var ByteIndex := 0 to P.MidiPendingCount - 1 do
          begin
            var DataByte := Integer(P.MidiPending[ByteIndex]);
            S.Int(DataByte);
            if not InRange(DataByte, 0, 127) then
              raise EReadError.Create('Invalid snapshot MIDI data byte');
            P.MidiPending[ByteIndex] := Byte(DataByte);
          end;
          if not ValidMidiInputState(P.MidiStatus, P.MidiPendingCount) then
            raise EReadError.Create('Invalid snapshot MIDI input state');
          if Timed then
          begin
            var Timing := Default(TMidiPlaybackTiming);
            if not S.Loading then
              Timing := P.MidiTiming.CaptureTiming;
            S.Int(Timing.Rate);
            S.Int(Timing.TempoOverride);
            S.Int(Timing.NextEvent);
            S.RealValue(Timing.Fraction);
            S.Bool(Timing.Released);
            if S.Loading then
            begin
              P.MidiTiming := P.Decoder as IMidiTimingSource;
              P.MidiTiming.RestoreTiming(Timing);
            end;
          end;
        end;
      end;
      if P.MidiDevice then
        if (P.ContentType <> 'audio/midi') or (Length(P.Data) <> 0) or (Length(P.PCM) <> 0) or
          (P.SampleCount <> 0) or P.Streaming or ((P.State >= 300) <> Live) or (P.Rooted <> (P.State = 400)) or
          ((P.State = 100) and ((P.FrameCount <> 0) or (P.Position <> 0))) or
          ((P.State >= 200) and ((P.FrameCount <> MidiDeviceFrameLimit) or (P.Info.SampleRate <> 44100) or
          (P.Info.Channels <> 2) or (P.Position < 0) or (P.Position > P.FrameCount * 44100))) then
          raise EReadError.Create('Invalid snapshot MIDI device');
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
      var VideoPlayer := J2MEVideoContentType(P.ContentType);
      if VideoPlayer and (P.State >= 200) then
      begin
        if P.MidiDevice or P.Streaming or P.Decoding or (P.Info.SampleRate <> VideoClockRate) or
          (P.Info.Channels <> 0) or (P.SampleCount <> 0) or (Length(P.PCM) <> 0) or
          (P.FrameCount < 1000) or (P.FrameCount > J2MEVideoMaxDuration) or
          (P.Position < 0) or (P.Position > P.FrameCount * 44100) or (P.Rooted <> (P.State = 400)) then
          raise EReadError.Create('Invalid MP4 player snapshot');
        if S.Loading then
        begin
          OpenVideo(P);
          // Older snapshots used the picture duration for the whole player.
          if (P.FrameCount <> P.Video.Duration) and (P.FrameCount <> P.Video.Info.Duration) then
            raise EReadError.Create('MP4 player snapshot duration mismatch');
          P.FrameCount := P.Video.Duration;
          FVideoDirty := True;
        end;
      end;
      if not VideoPlayer and not P.MidiDevice and not P.Streaming and not P.Decoding and (P.State >= 200) then
        if not (P.Info.Channels in [1, 2]) or (P.Info.SampleRate < 1) or (P.Info.SampleRate > 384000) or
          (P.SampleCount mod P.Info.Channels <> 0) or (P.FrameCount <> P.SampleCount div P.Info.Channels) or
          (P.Position < 0) or (P.Position > P.FrameCount * 44100) then
          raise EReadError.Create('Invalid snapshot media frame count');
      if S.Loading and (P.ContentType = J2METoneContentType) and (P.State >= 200) then
      begin
        var Frames: Int64 := 0;
        if Length(P.Data) > 0 then
          P.Decoder := OpenJ2METoneSequence(P.Data, Frames);
        if (P.Info.SampleRate <> J2METoneRate) or (P.Info.Channels <> 1) or
          (P.FrameCount <> Frames) or (P.Streaming <> (Frames > 0)) or
          P.Decoding or P.MidiDevice then
          raise EReadError.Create('Invalid tone sequence snapshot');
      end;
      if S.Loading and (P.ContentType = IMelodyContentType) and (P.State >= 200) then
      begin
        var Frames: Int64;
        OpenMelody(P, Frames);
        if (P.Info.SampleRate <> IMelodySampleRate) or (P.Info.Channels <> 1) or
          (P.FrameCount <> Frames) or not P.Streaming or P.Decoding or P.MidiDevice then
          raise EReadError.Create('Invalid iMelody snapshot');
      end;
      if S.Loading and P.Decoding and (P.SampleCount > 0) then
      begin
        P.Decoder := RestoreJ2MEDecoder(P.Data, MediaDecoderExtension(P.ContentType),
          P.SampleCount, P.Info.SampleRate, P.Info.Channels);
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

