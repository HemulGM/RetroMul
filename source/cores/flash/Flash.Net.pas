unit Flash.Net;

interface

uses
  System.SysUtils, System.Generics.Collections, AVM1.Runtime, SWF.Video, SWF.FLV,
  Flash.Audio, Media.Image.PixelBuffer;

type
  TFlashNetRead = reference to function(const BaseURI, URL: string; out Data: TBytes; out ResolvedURI: string): Boolean;

  TFlashNetRuntime = class;

  TFlashStreamState = class
  private
    Runtime: TFlashNetRuntime;
    Obj: TAVMObject;
    Media: TFLVMovie;
    Video: TSWFVideoState;
    URI, BaseURI: string;
    Time, LastTick: Int64;
    NextScript: Integer;
    ScriptGeneration: UInt64;
    Pending, Paused, Finished, AudioStarted: Boolean;
    BufferTime: Double;
  public
    destructor Destroy; override;
  end;

  TFlashNetRuntime = class
  private
    FVM: TAVM1;
    FAudio: TFlashAudio;
    FRead: TFlashNetRead;
    FPool: IImagePixelPool;
    FStreams: TList<TFlashStreamState>;
    FVideoPrototype: TAVMObject;
    FMemory: Int64;
    FScriptGeneration: UInt64;
    procedure Status(O: TAVMObject; const Code, Level: string; const Detail: string = '');
    procedure Reset(State: TFlashStreamState);
    procedure ReadStream(State: TFlashStreamState);
    procedure DecodeVideo(State: TFlashStreamState; var Work: Int64);
    procedure StartAudio(State: TFlashStreamState);
    function DispatchScripts(State: TFlashStreamState; var ByteBudget, ValueBudget, EventBudget: Integer): Boolean;
    procedure QueueScript(Receiver: TAVMObject; Generation: UInt64; const Name: string; const Value: TAVMValue);
  public
    constructor Create(VM: TAVM1; Audio: TFlashAudio; const Reader: TFlashNetRead; const Pool: IImagePixelPool);
    destructor Destroy; override;
    function Call(const Name, BaseURI: string; Receiver: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
    function IsStream(O: TAVMObject): Boolean;
    function Bitmap(O: TAVMObject): IImagePixelBuffer;
    procedure Tick;
    procedure VisitRoots(const Visit: TProc<TAVMObject>);
    property VideoPrototype: TAVMObject read FVideoPrototype;
  end;

implementation

uses
  System.Classes, System.Math, Flash.Filters, SWF.Reader, SWF.Sound,
  SWF.FLV.Script;

const
  FlashStreamMemoryLimit = 128 * 1024 * 1024;

type
  TFlashConnectionState = class
    Connected: Boolean;
  end;

function StreamOf(O: TAVMObject): TFlashStreamState;
begin
  Result := nil;
  if (O <> nil) and (O.OwnedNativeData is TFlashStreamState) then
    Result := TFlashStreamState(O.OwnedNativeData);
end;

destructor TFlashStreamState.Destroy;
begin
  if Runtime <> nil then
  begin
    Runtime.Reset(Self);
    Runtime.FStreams.Remove(Self);
  end;
  inherited;
end;

constructor TFlashNetRuntime.Create(VM: TAVM1; Audio: TFlashAudio; const Reader: TFlashNetRead; const Pool: IImagePixelPool);
var
  PrototypeObject: TAVMObject;
  Name: string;

  function InstallClass(const ClassName: string; const Methods: array of string): TAVMObject;
  var
    ConstructorValue: TAVMValue;
    MethodName: string;
  begin
    ConstructorValue := VM.NativeFunction(ClassName);
    Result := VM.NewObject;
    VM.PutData(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(Result));
    VM.PutData(Result, 'constructor', ConstructorValue);
    Result.Attributes.AddOrSetValue('constructor', 1);
    for MethodName in Methods do
    begin
      VM.PutData(Result, MethodName, VM.NativeFunction(ClassName + '.' + MethodName));
      Result.Attributes.AddOrSetValue(MethodName, 3);
    end;
    VM.PutData(VM.Global, ClassName, ConstructorValue);
    VM.Global.Attributes.AddOrSetValue(ClassName, $81);
  end;

begin
  inherited Create;
  FVM := VM;
  FAudio := Audio;
  FRead := Reader;
  FPool := Pool;
  FStreams := TList<TFlashStreamState>.Create;
  PrototypeObject := InstallClass('NetConnection', ['connect', 'close']);
  for Name in ['isConnected', 'protocol', 'uri'] do
    VM.AddProperty(PrototypeObject, Name, VM.NativeFunction('NetConnection.' + Name).Obj, nil);
  PrototypeObject := InstallClass('NetStream', ['play', 'pause', 'seek', 'close', 'setBufferTime']);
  for Name in ['time', 'bufferTime', 'bufferLength', 'bytesLoaded', 'bytesTotal'] do
    VM.AddProperty(PrototypeObject, Name, VM.NativeFunction('NetStream.' + Name).Obj, nil);
  FVideoPrototype := InstallClass('Video', ['attachVideo']);
  for Name in ['width', 'height'] do
    VM.AddProperty(FVideoPrototype, Name, VM.NativeFunction('Video.' + Name).Obj, nil);
end;

destructor TFlashNetRuntime.Destroy;
begin
  FStreams.Free;
  inherited;
end;

procedure TFlashNetRuntime.Status(O: TAVMObject; const Code, Level: string; const Detail: string);
var
  Info: TAVMObject;
begin
  Info := FVM.NewObject;
  FVM.PutData(Info, 'code', TAVMValue.Str(Code));
  FVM.PutData(Info, 'level', TAVMValue.Str(Level));
  if Detail <> '' then
    FVM.PutData(Info, 'description', TAVMValue.Str(Detail));
  FVM.QueueEvent(O, 'onStatus', [TAVMValue.Ref(Info)]);
end;

procedure TFlashNetRuntime.Reset(State: TFlashStreamState);
begin
  FAudio.StopStream(State);
  if State.Media <> nil then
    Dec(FMemory, State.Media.MemorySize);
  FreeAndNil(State.Media);
  State.Video := Default(TSWFVideoState);
  State.Pending := False;
  State.Paused := False;
  State.Finished := False;
  State.AudioStarted := False;
  State.Time := 0;
  State.NextScript := 0;
  Inc(FScriptGeneration);
  State.ScriptGeneration := FScriptGeneration;
  State.URI := '';
  State.BaseURI := '';
end;

procedure TFlashNetRuntime.DecodeVideo(State: TFlashStreamState; var Work: Int64);
var
  Frame: Integer;
begin
  Frame := State.Media.FrameAt(State.Time);
  if Frame >= 0 then
    State.Media.Video.Seek(Frame, State.Video, FPool, Work, FlashRenderWorkLimit)
  else
    State.Video := Default(TSWFVideoState);
end;

procedure TFlashNetRuntime.ReadStream(State: TFlashStreamState);
var
  Data: TBytes;
  Resolved: string;
  Loaded: Boolean;
begin
  State.Pending := False;
  try
    Loaded := Assigned(FRead) and FRead(State.BaseURI, State.URI, Data, Resolved);
    if not Loaded then
    begin
      Status(State.Obj, 'NetStream.Play.StreamNotFound', 'error');
      Exit;
    end;
    if Int64(Length(Data)) + FMemory > FlashStreamMemoryLimit then
      raise ESWFError.Create('Flash stream memory limit');
    State.Media := TFLVMovie.Create(Data);
    Inc(FMemory, State.Media.MemorySize);
    if FMemory > FlashStreamMemoryLimit then
      raise ESWFError.Create('Flash stream memory limit');
  except
    on E: ESWFError do
    begin
      Reset(State);
      Status(State.Obj, 'NetStream.Play.Failed', 'error', E.Message);
      Exit;
    end;
    on E: EInOutError do
    begin
      Reset(State);
      Status(State.Obj, 'NetStream.Play.StreamNotFound', 'error', E.Message);
      Exit;
    end;
    on E: EStreamError do
    begin
      Reset(State);
      Status(State.Obj, 'NetStream.Play.StreamNotFound', 'error', E.Message);
      Exit;
    end;
  end;
  State.LastTick := FVM.Milliseconds;
  Status(State.Obj, 'NetStream.Play.Start', 'status');
  Status(State.Obj, 'NetStream.Buffer.Full', 'status');
end;

procedure TFlashNetRuntime.StartAudio(State: TFlashStreamState);
var
  First: Int64;
  Audio: TSWFSound;
begin
  if State.Paused or State.Finished or State.AudioStarted or
    (State.Time < State.Media.AudioStart) then
    Exit;
  Audio := State.Media.Audio;
  if Audio = nil then
    Exit;
  State.AudioStarted := True;
  First := (State.Time - State.Media.AudioStart) * Audio.SampleRate div 1000;
  if First < Audio.FrameCount then
    FAudio.StartStream(Audio, State, Integer(First), Audio.FrameCount);
end;

procedure TFlashNetRuntime.QueueScript(Receiver: TAVMObject; Generation: UInt64; const Name: string; const Value: TAVMValue);
begin
  FVM.QueueEvent(Receiver, Name, [Value],
    function: Boolean
    var
      State: TFlashStreamState;
    begin
      State := StreamOf(Receiver);
      Result := (State <> nil) and (State.ScriptGeneration = Generation);
    end);
end;

function TFlashNetRuntime.DispatchScripts(State: TFlashStreamState; var ByteBudget, ValueBudget, EventBudget: Integer): Boolean;
var
  Tags: TArray<TFLVScriptTag>;
  Script: TFLVScriptData;
  Event: TFLVScriptValue;
  Objects: TDictionary<TFLVScriptValue, TAVMObject>;

  function ToAVM(Value: TFLVScriptValue): TAVMValue;
  var
    Obj: TAVMObject;
    Values: TArray<TAVMValue>;
    Child: TFLVScriptValue;
    I: Integer;
  begin
    case Value.Kind of
      skNull:
        Result := TAVMValue.Ref(nil);
      skNumber:
        Result := TAVMValue.Num(Value.Number);
      skBoolean:
        Result := TAVMValue.Bool(Value.Flag);
      skString:
        Result := TAVMValue.Str(Value.Text);
      skObject:
        begin
          Obj := FVM.NewObject;
          Objects.Add(Value, Obj);
          for Child in Value.Children do
            Obj.StoreData(Child.Name, ToAVM(Child));
          Result := TAVMValue.Ref(Obj);
        end;
      skArray:
        begin
          SetLength(Values, Length(Value.Children));
          Obj := FVM.CreateArray(Values);
          Objects.Add(Value, Obj);
          for I := 0 to High(Values) do
            Obj.StoreData(IntToStr(I), ToAVM(Value.Children[I]));
          Result := TAVMValue.Ref(Obj);
        end;
      skDate:
        begin
          Obj := FVM.NewObject('Date');
          Obj.IsDate := True;
          Obj.DateValue := Value.Number;
          Result := TAVMValue.Ref(Obj);
        end;
      skReference:
        begin
          if Objects.TryGetValue(Value.Reference, Obj) then
            Result := TAVMValue.Ref(Obj)
          else
            Result := Default(TAVMValue);
        end;
    else
      Result := Default(TAVMValue);
    end;
  end;

begin
  Tags := State.Media.Scripts;
  while (State.NextScript < Length(Tags)) and (Tags[State.NextScript].Time <= State.Time) do
  begin
    if (Length(Tags[State.NextScript].Data) > ByteBudget) or
      (ValueBudget <= 0) or (EventBudget <= 0) then
      Exit(False);
    Dec(ByteBudget, Length(Tags[State.NextScript].Data));
    try
      Script := TFLVScriptData.Create(Tags[State.NextScript].Data);
    except
      on E: ESWFError do
      begin
        Inc(State.NextScript);
        Dec(ValueBudget);
        Continue;
      end;
    end;
    try
      if (Script.ValueCount > ValueBudget) or (Length(Script.Events) > EventBudget) then
        Exit(False);
      Dec(ValueBudget, Script.ValueCount);
      Dec(EventBudget, Length(Script.Events));
      Inc(State.NextScript);
      Objects := TDictionary<TFLVScriptValue, TAVMObject>.Create;
      try
        for Event in Script.Events do
          QueueScript(State.Obj, State.ScriptGeneration, Event.Name, ToAVM(Event));
      finally
        Objects.Free;
      end;
    finally
      Script.Free;
    end;
  end;
  Result := True;
end;

procedure TFlashNetRuntime.Tick;
var
  State: TFlashStreamState;
  Work: Int64;
  ByteBudget, ValueBudget, EventBudget: Integer;
begin
  Work := 0;
  ByteBudget := 2 * FLVScriptTagLimit;
  ValueBudget := 8192;
  EventBudget := 256;
  for State in FStreams do
  begin
    if State.Pending then
      ReadStream(State);
    if State.Media = nil then
      Continue;
    if not (State.Paused or State.Finished) then
      State.Time := Min(State.Media.Duration, State.Time + Max(Int64(0), FVM.Milliseconds - State.LastTick));
    State.LastTick := FVM.Milliseconds;
    try
      DecodeVideo(State, Work);
    except
      on E: ESWFError do
      begin
        Reset(State);
        Status(State.Obj, 'NetStream.Play.Failed', 'error', E.Message);
        Continue;
      end;
    end;
    if not (State.Paused or State.Finished) and
      not DispatchScripts(State, ByteBudget, ValueBudget, EventBudget) then
    begin
      StartAudio(State);
      Continue;
    end;
    if not State.Finished and (State.Time >= State.Media.Duration) then
    begin
      State.Finished := True;
      FAudio.StopStream(State);
      Status(State.Obj, 'NetStream.Buffer.Flush', 'status');
      Status(State.Obj, 'NetStream.Play.Stop', 'status');
    end
    else
      StartAudio(State);
  end;
end;

procedure TFlashNetRuntime.VisitRoots(const Visit: TProc<TAVMObject>);
var
  State: TFlashStreamState;
begin
  Visit(FVideoPrototype);
  for State in FStreams do
    if State.Pending or ((State.Media <> nil) and not State.Paused and not State.Finished) then
      Visit(State.Obj);
end;

function TFlashNetRuntime.IsStream(O: TAVMObject): Boolean;
begin
  Result := StreamOf(O) <> nil;
end;

function TFlashNetRuntime.Bitmap(O: TAVMObject): IImagePixelBuffer;
var
  State: TFlashStreamState;
begin
  State := StreamOf(O);
  Result := nil;
  if State <> nil then
    Result := State.Video.Bitmap;
end;

function TFlashNetRuntime.Call(const Name, BaseURI: string; Receiver: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  Conn: TFlashConnectionState;
  State: TFlashStreamState;
  Value: TAVMValue;
  Seconds: Double;
  Pause: Boolean;
  URL: string;
  SeekTarget: Int64;
begin
  Result := Default(TAVMValue);
  if Receiver = nil then
    Exit;
  Value := Default(TAVMValue);
  if Length(Args) > 0 then
    Value := Args[0];
  if Name = 'NetConnection' then
  begin
    Receiver.OwnedNativeData.Free;
    Receiver.OwnedNativeData := TFlashConnectionState.Create;
    Exit;
  end;
  if Name = 'NetStream' then
  begin
    Receiver.OwnedNativeData.Free;
    State := TFlashStreamState.Create;
    State.Runtime := Self;
    State.Obj := Receiver;
    State.BufferTime := 0.1;
    Receiver.OwnedNativeData := State;
    FStreams.Add(State);
    Exit;
  end;
  if Name.StartsWith('NetConnection.') then
  begin
    if not (Receiver.OwnedNativeData is TFlashConnectionState) then
      Exit;
    Conn := TFlashConnectionState(Receiver.OwnedNativeData);
    if Name = 'NetConnection.isConnected' then
      Exit(TAVMValue.Bool(Conn.Connected));
    if Name = 'NetConnection.close' then
    begin
      if Conn.Connected then
        Status(Receiver, 'NetConnection.Connect.Closed', 'status');
      Conn.Connected := False;
    end
    else if Name = 'NetConnection.connect' then
    begin
      Conn.Connected := Value.Kind in [avNull, avUndefined];
      if Conn.Connected then
        Status(Receiver, 'NetConnection.Connect.Success', 'status')
      else
        Status(Receiver, 'NetConnection.Connect.Failed', 'error');
      Result := TAVMValue.Bool(Conn.Connected);
    end;
    Exit;
  end;
  State := StreamOf(Receiver);
  if State = nil then
    Exit;
  if Name = 'NetStream.close' then
    Reset(State)
  else if Name = 'NetStream.play' then
  begin
    if Value.Kind in [avNull, avUndefined] then
      State.Paused := False
    else
    begin
      URL := FVM.CoerceString(Value);
      if StreamOf(Receiver) <> State then
        Exit;
      Reset(State);
      State.URI := URL;
      State.BaseURI := BaseURI;
      State.Pending := True;
    end;
    State.LastTick := FVM.Milliseconds;
  end
  else if Name = 'NetStream.pause' then
  begin
    if Value.Kind = avUndefined then
      Pause := not State.Paused
    else
      Pause := Value.AsBoolean(FVM.SWFVersion);
    if Pause <> State.Paused then
    begin
      State.Paused := Pause;
      State.LastTick := FVM.Milliseconds;
      if Pause then
      begin
        FAudio.StopStream(State);
        State.AudioStarted := False;
      end;
    end;
  end
  else if Name = 'NetStream.seek' then
  begin
    Seconds := FVM.CoerceNumber(Value);
    if (StreamOf(Receiver) <> State) or (State.Media = nil) then
      Exit;
    if IsNan(Seconds) or (Seconds < 0) or (Seconds > State.Media.Duration / 1000.0) then
    begin
      Status(Receiver, 'NetStream.Seek.InvalidTime', 'error');
      Exit;
    end;
    FAudio.StopStream(State);
    State.AudioStarted := False;
    State.Finished := False;
    State.LastTick := FVM.Milliseconds;
    SeekTarget := State.Media.SeekTime(Trunc(Seconds * 1000));
    if State.Time <> SeekTarget then
    begin
      State.Time := SeekTarget;
      State.NextScript := State.Media.FirstScriptAt(State.Time);
      Inc(FScriptGeneration);
      State.ScriptGeneration := FScriptGeneration;
    end;
    Status(Receiver, 'NetStream.Seek.Notify', 'status');
  end
  else if Name = 'NetStream.setBufferTime' then
  begin
    Seconds := FVM.CoerceNumber(Value);
    if (StreamOf(Receiver) = State) and not IsNan(Seconds) then
      State.BufferTime := Max(0.0, Seconds);
  end
  else if Name = 'NetStream.time' then
    Result := TAVMValue.Num(State.Time / 1000.0)
  else if Name = 'NetStream.bufferTime' then
    Result := TAVMValue.Num(State.BufferTime)
  else if Name = 'NetStream.bufferLength' then
  begin
    Seconds := 0;
    if State.Media <> nil then
      Seconds := (State.Media.Duration - State.Time) / 1000.0;
    Result := TAVMValue.Num(Seconds);
  end
  else if (Name = 'NetStream.bytesLoaded') or (Name = 'NetStream.bytesTotal') then
  begin
    Result := TAVMValue.Num(0);
    if State.Media <> nil then
      Result := TAVMValue.Num(State.Media.Bytes);
  end;
end;

end.

