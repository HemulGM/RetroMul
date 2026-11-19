unit J2ME.Siemens.Game;

interface

uses
  System.Classes, JVM.StateIO, System.SysUtils, System.Generics.Collections,
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.Effects;

type
  TSiemensNote = record
    Note, Length, Target: Integer;
    TimedBody: Boolean;
  end;

  TSiemensComposer = class
  public
    BPM: Integer;
    Notes: TList<TSiemensNote>;
    constructor Create;
    destructor Destroy; override;
  end;

  TSiemensMelody = class
  public
    Reference, BPM, Cursor: Integer;
    Notes: TArray<TSiemensNote>;
    Repeats: TArray<Integer>;
    RepeatActive: TArray<Boolean>;
    Rooted, Silent: Boolean;
    Remaining, Remainder: Int64;
    Phase, Increment: Double;
    procedure Reset;
    function NextSegment: Boolean;
  end;
  // Native Siemens game APIs. All state belongs to this VM; audio is streamed
  // through the existing J2ME mixer, never sent to a platform API here.

  TJ2MESiemensGame = class
  private
    FVM: TJVM;
    FEffects: TJ2MEDeviceEffects; // borrowed
    FComposers: TObjectDictionary<Integer, TSiemensComposer>;
    FMelodies: TObjectDictionary<Integer, TSiemensMelody>;
    FCurrent: TSiemensMelody;
    FToneRemaining: Int64;
    FTonePhase, FToneIncrement: Double;
    FSilentTone: Boolean;
    function Composer(Ref: Integer): TSiemensComposer;
    procedure Sweep;
    procedure ReserveObject;
    procedure StopMelody;
    procedure ValidateNote(Note, Length: Integer);
  public
    procedure TransferState(S: TJVMStateIO);
    constructor Create(VM: TJVM; Effects: TJ2MEDeviceEffects);
    destructor Destroy; override;
    procedure Install;
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    procedure MixInto(var Mix: TArray<Int64>; Frames: Integer);
    procedure Shutdown;
  end;

implementation

uses
  System.Math, Java.Classes;

const
  Prefix = 'com/siemens/mp/game/';
  ComposerName = Prefix + 'MelodyComposer';
  MelodyName = Prefix + 'Melody';
  SoundName = Prefix + 'Sound';
  LightName = Prefix + 'Light';
  VibratorName = Prefix + 'Vibrator';
  NativeMem = 'com/siemens/mp/misc/NativeMem';
  DebugName = 'com/siemens/mp/misc/Debug';
  MaxNotes = 4096;
  MaxObjects = 256;

constructor TSiemensComposer.Create;
begin
  inherited Create;
  BPM := 60;
  Notes := TList<TSiemensNote>.Create;
end;

destructor TSiemensComposer.Destroy;
begin
  Notes.Free;
  inherited;
end;

procedure TSiemensMelody.Reset;
begin
  Cursor := 0;
  Remaining := 0;
  Remainder := 0;
  Phase := 0;
  SetLength(Repeats, Length(Notes));
  SetLength(RepeatActive, Length(Notes));
  for var I := 0 to High(RepeatActive) do
    RepeatActive[I] := False;
end;

function TSiemensMelody.NextSegment: Boolean;
begin
  Result := False;
  // Control-only cycles have no audio time. Bound their work independently of
  // guest repeat counts; no expanded PCM or expanded repeated score is stored.
  for var Work := 0 to Length(Notes) * 2 do
  begin
    if Cursor >= Length(Notes) then
      Exit;
    var Index := Cursor;
    var N := Notes[Index];
    Inc(Cursor);
    if N.Note < 60 then
    begin
      var Units := Int64(128 shr (N.Length mod 7));
      if N.Length >= 7 then
        Units := Units * 3 div 2;
      var Numerator := Int64(44100) * 240 * Units + Remainder;
      var Denominator := Int64(BPM) * 128;
      Remaining := Max(Int64(1), Numerator div Denominator);
      Remainder := Numerator mod Denominator;
      Silent := N.Note >= 58;
      Phase := 0;
      // Virtual phone calibration: C0=MIDI48. The vendor API specifies note IDs
      // and octaves, but not an absolute Hz table or handset beeper waveform.
      var Frequency := 440 * Power(2, (N.Note + 48 - 69) / 12);
      Increment := 2 * Pi * Frequency / 44100;
      Exit(True);
    end;
    if N.Note = 60 then
      Exit;
    if N.Note = 64 then
      Continue;
    if not N.TimedBody then
    begin
      if N.Note in [61, 62, 65, 66] then
        Exit;
      Continue;
    end;
    if N.Note in [62, 66] then
    begin
      Cursor := N.Target;
      Continue;
    end;
    if not RepeatActive[Index] then
    begin
      Repeats[Index] := N.Length;
      RepeatActive[Index] := True;
    end;
    if Repeats[Index] > 0 then
    begin
      Dec(Repeats[Index]);
      Cursor := N.Target;
      Continue;
    end;
    RepeatActive[Index] := False;
    if N.Note in [61, 65] then
      Exit;
  end;
end;

constructor TJ2MESiemensGame.Create(VM: TJVM; Effects: TJ2MEDeviceEffects);
begin
  inherited Create;
  FVM := VM;
  FEffects := Effects;
  FComposers := TObjectDictionary<Integer, TSiemensComposer>.Create([doOwnsValues]);
  FMelodies := TObjectDictionary<Integer, TSiemensMelody>.Create([doOwnsValues]);
end;

destructor TJ2MESiemensGame.Destroy;
begin
  Shutdown;
  FMelodies.Free;
  FComposers.Free;
  inherited;
end;

procedure TJ2MESiemensGame.Install;
var
  B: TJavaClassBuilder;
  C: TJVMClass;

  procedure Constant(const Name: string; Value: Integer);
  begin
    B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

begin
  B := TJavaClassBuilder.Create(DebugName, 'java/lang/Object', JVM_ACC_PUBLIC or $20);
  try
    B.Start;
    // A guest breakpoint has no effect during normal gameplay.
    B.Emit([$B1]);
    B.Finish('breakpoint', '()V', JVM_ACC_PUBLIC or JVM_ACC_STATIC, 0, 0);
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  C := TJVMClass.Create;
  C.Name := NativeMem;
  C.SuperName := 'java/lang/Object';
  C.Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  FVM.DefineClass(C);
  C := TJVMClass.Create;
  C.Name := MelodyName;
  C.SuperName := NativeMem;
  C.AddNative('play', '()V');
  C.AddNative('stop', '()V', True);
  FVM.DefineClass(C);
  B := TJavaClassBuilder.Create(ComposerName, 'java/lang/Object', JVM_ACC_PUBLIC or $20);
  try
    Constant('BPM', 60);
    Constant('NO_TONE', 59);
    Constant('TONE_A0', 9);
    Constant('TONE_A1', 21);
    Constant('TONE_A2', 33);
    Constant('TONE_A3', 45);
    Constant('TONE_A4', 57);
    Constant('TONE_AIS0', 10);
    Constant('TONE_AIS1', 22);
    Constant('TONE_AIS2', 34);
    Constant('TONE_AIS3', 46);
    Constant('TONE_C0', 0);
    Constant('TONE_C1', 12);
    Constant('TONE_C2', 24);
    Constant('TONE_C3', 36);
    Constant('TONE_C4', 48);
    Constant('TONE_CIS0', 1);
    Constant('TONE_CIS1', 13);
    Constant('TONE_CIS2', 25);
    Constant('TONE_CIS3', 37);
    Constant('TONE_CIS4', 49);
    Constant('TONE_D0', 2);
    Constant('TONE_D1', 14);
    Constant('TONE_D2', 26);
    Constant('TONE_D3', 38);
    Constant('TONE_D4', 50);
    Constant('TONE_DIS0', 3);
    Constant('TONE_DIS1', 15);
    Constant('TONE_DIS2', 27);
    Constant('TONE_DIS3', 39);
    Constant('TONE_DIS4', 51);
    Constant('TONE_E0', 4);
    Constant('TONE_E1', 16);
    Constant('TONE_E2', 28);
    Constant('TONE_E3', 40);
    Constant('TONE_E4', 52);
    Constant('TONE_F0', 5);
    Constant('TONE_F1', 17);
    Constant('TONE_F2', 29);
    Constant('TONE_F3', 41);
    Constant('TONE_F4', 53);
    Constant('TONE_FIS0', 6);
    Constant('TONE_FIS1', 18);
    Constant('TONE_FIS2', 30);
    Constant('TONE_FIS3', 42);
    Constant('TONE_FIS4', 54);
    Constant('TONE_G0', 7);
    Constant('TONE_G1', 19);
    Constant('TONE_G2', 31);
    Constant('TONE_G3', 43);
    Constant('TONE_G4', 55);
    Constant('TONE_GIS0', 8);
    Constant('TONE_GIS1', 20);
    Constant('TONE_GIS2', 32);
    Constant('TONE_GIS3', 44);
    Constant('TONE_GIS4', 56);
    Constant('TONE_H0', 11);
    Constant('TONE_H1', 23);
    Constant('TONE_H2', 35);
    Constant('TONE_H3', 47);
    Constant('TONE_MARK', 64);
    Constant('TONE_PAUSE', 58);
    Constant('TONE_REPEAT', 61);
    Constant('TONE_REPEAT_MARK', 65);
    Constant('TONE_REPEV', 62);
    Constant('TONE_REPEV_MARK', 66);
    Constant('TONE_REPON', 63);
    Constant('TONE_REPON_MARK', 67);
    Constant('TONE_STOP', 60);
    Constant('TONELENGTH_1_1', 0);
    Constant('TONELENGTH_1_16', 4);
    Constant('TONELENGTH_1_2', 1);
    Constant('TONELENGTH_1_32', 5);
    Constant('TONELENGTH_1_4', 2);
    Constant('TONELENGTH_1_64', 6);
    Constant('TONELENGTH_1_8', 3);
    Constant('TONELENGTH_DOTTED_1_1', 7);
    Constant('TONELENGTH_DOTTED_1_16', 11);
    Constant('TONELENGTH_DOTTED_1_2', 8);
    Constant('TONELENGTH_DOTTED_1_32', 12);
    Constant('TONELENGTH_DOTTED_1_4', 9);
    Constant('TONELENGTH_DOTTED_1_64', 13);
    Constant('TONELENGTH_DOTTED_1_8', 10);
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('<init>', '([II)V');
    B.JavaClass.AddNative('appendNote', '(II)V');
    B.JavaClass.AddNative('setBPM', '(I)V');
    B.JavaClass.AddNative('getMelody', '()Lcom/siemens/mp/game/Melody;');
    B.JavaClass.AddNative('length', '()I');
    B.JavaClass.AddNative('maxLength', '()I', True);
    B.JavaClass.AddNative('resetMelody', '()V');
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  for var Name in [SoundName, LightName, VibratorName] do
  begin
    C := TJVMClass.Create;
    C.Name := Name;
    C.SuperName := 'java/lang/Object';
    C.AddNative('<init>', '()V');
    if Name = SoundName then
      C.AddNative('playTone', '(II)V', True)
    else if Name = LightName then
    begin
      C.AddNative('setLightOn', '()V', True);
      C.AddNative('setLightOff', '()V', True);
    end
    else
    begin
      C.AddNative('startVibrator', '()V', True);
      C.AddNative('stopVibrator', '()V', True);
      C.AddNative('triggerVibrator', '(I)V', True);
    end;
    FVM.DefineClass(C);
  end;
end;

function TJ2MESiemensGame.Handles(const Owner: string): Boolean;
begin
  Result := (Owner = ComposerName) or (Owner = MelodyName) or (Owner = SoundName) or
    (Owner = LightName) or (Owner = VibratorName);
end;

procedure TJ2MESiemensGame.Sweep;
begin
  for var Ref in FComposers.Keys.ToArray do
    if not FVM.IsObjectAlive(Ref) then
      FComposers.Remove(Ref);
  for var Ref in FMelodies.Keys.ToArray do
    if not FVM.IsObjectAlive(Ref) then
      FMelodies.Remove(Ref);
end;

procedure TJ2MESiemensGame.ReserveObject;
begin
  Sweep;
  if FComposers.Count + FMelodies.Count >= MaxObjects then
  begin
    FVM.CollectGarbage;
    Sweep;
  end;
  if FComposers.Count + FMelodies.Count >= MaxObjects then
    FVM.RaiseJava('java/lang/OutOfMemoryError', 'Siemens score object limit');
end;

function TJ2MESiemensGame.Composer(Ref: Integer): TSiemensComposer;
begin
  FVM.GetObject(Ref);
  if FComposers.TryGetValue(Ref, Result) then
    Exit;
  ReserveObject;
  Result := TSiemensComposer.Create;
  FComposers.Add(Ref, Result);
end;

procedure TJ2MESiemensGame.ValidateNote(Note, Length: Integer);
begin
  if (Note < 0) or (Note > 67) or ((Note < 60) and ((Length < 0) or (Length > 13))) or
    ((Note in [61, 63, 65, 67]) and (Length < 0)) then
    FVM.RaiseJava('java/lang/Exception', 'Invalid Siemens melody note or length');
end;

procedure TJ2MESiemensGame.StopMelody;
begin
  if FCurrent = nil then
    Exit;
  if FCurrent.Rooted then
  begin
    FCurrent.Rooted := False;
    FVM.RemoveRoot(FCurrent.Reference);
  end;
  FCurrent := nil;
end;

function TJ2MESiemensGame.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  C: TSiemensComposer;
begin
  Result := Default(TJVMValue);
  var Owner := Method.Owner.Name;
  var Name := Method.Name;
  if Owner = LightName then
  begin
    if Name = '<init>' then
      Exit;
    FEffects.SetBacklight(100 * Ord(Name = 'setLightOn'), True);
    Exit;
  end;
  if Owner = VibratorName then
  begin
    if Name = '<init>' then
      Exit;
    var Duration := Int64(-1);
    if Name = 'stopVibrator' then
      Duration := 0
    else if Name = 'triggerVibrator' then
    begin
      Duration := Args[0].AsInt;
      if Duration < 0 then
        FVM.RaiseJava('java/lang/IllegalArgumentException');
    end;
    FEffects.SetVibration(100, Duration, FVM.Host.MonotonicMillis);
    Exit;
  end;
  if Owner = SoundName then
  begin
    if Name = '<init>' then
      Exit;
    var Frequency := Args[0].AsInt;
    var Millis := Args[1].AsInt;
    if (Frequency < 0) or (Frequency > 20000) or (Millis < 0) then
      FVM.RaiseJava('java/lang/IllegalArgumentException');
    FToneRemaining := Int64(Millis) * 44100 div 1000;
    FTonePhase := 0;
    FToneIncrement := 2 * Pi * Frequency / 44100;
    FSilentTone := Frequency = 0;
    Exit;
  end;
  if Owner = MelodyName then
  begin
    if Name = 'stop' then
    begin
      StopMelody;
      Exit;
    end;
    FVM.GetObject(Args[0].AsRef);
    var M: TSiemensMelody;
    if not FMelodies.TryGetValue(Args[0].AsRef, M) then
      FVM.RaiseJava('java/lang/IllegalStateException', 'Uninitialized Siemens melody');
    StopMelody;
    M.Reset;
    if M.NextSegment then
    begin
      FCurrent := M;
      M.Rooted := True;
      FVM.AddRoot(M.Reference);
    end;
    Exit;
  end;
  if Name = 'maxLength' then
    Exit(TJVMValue.Int(MaxNotes));
  C := Composer(Args[0].AsRef);
  if Name = '<init>' then
  begin
    var BPM := 60;
    if Length(Args) = 3 then
      BPM := Args[2].AsInt;
    if BPM <= 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException');
    var Input: TArray<TSiemensNote>;
    if Length(Args) = 3 then
    begin
      var A := FVM.GetObject(Args[1].AsRef);
      if (Length(A.Elements) mod 2 <> 0) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens note pairs');
      if Length(A.Elements) div 2 > MaxNotes then
        FVM.RaiseJava('java/lang/OutOfMemoryError', 'Siemens score length');
      SetLength(Input, Length(A.Elements) div 2);
      for var I := 0 to High(Input) do
      begin
        Input[I].Note := A.Elements[I * 2].AsInt;
        Input[I].Length := A.Elements[I * 2 + 1].AsInt;
        ValidateNote(Input[I].Note, Input[I].Length);
      end;
    end;
    C.Notes.Clear;
    C.Notes.AddRange(Input);
    C.BPM := BPM;
    Exit;
  end;
  if Name = 'length' then
    Exit(TJVMValue.Int(C.Notes.Count));
  if Name = 'resetMelody' then
  begin
    C.Notes.Clear;
    Exit;
  end;
  if Name = 'setBPM' then
  begin
    if Args[1].AsInt <= 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException');
    C.BPM := Args[1].AsInt;
    Exit;
  end;
  if Name = 'appendNote' then
  begin
    var N: TSiemensNote := Default(TSiemensNote);
    N.Note := Args[1].AsInt;
    N.Length := Args[2].AsInt;
    ValidateNote(N.Note, N.Length);
    if C.Notes.Count >= MaxNotes then
      FVM.RaiseJava('java/lang/Exception', 'Siemens melody is full');
    C.Notes.Add(N);
    Exit;
  end;
  if Name = 'getMelody' then
  begin
    ReserveObject;
    var Ref := FVM.NewObject(MelodyName);
    var M := TSiemensMelody.Create;
    try
      M.Reference := Ref;
      M.BPM := C.BPM;
      M.Notes := C.Notes.ToArray;
      var Mark := 0;
      var Timed := 0;
      var MarkTimed := 0;
      for var I := 0 to High(M.Notes) do
      begin
        if M.Notes[I].Note < 60 then
          Inc(Timed);
        if M.Notes[I].Note = 64 then
        begin
          Mark := I + 1;
          MarkTimed := Timed;
        end;
        if M.Notes[I].Note >= 65 then
        begin
          M.Notes[I].Target := Mark;
          M.Notes[I].TimedBody := Timed > MarkTimed;
        end
        else
          M.Notes[I].TimedBody := Timed > 0;
      end;
      FMelodies.Add(Ref, M);
    except
      M.Free;
      raise;
    end;
    Exit(TJVMValue.Ref(Ref));
  end;
  raise EJVMUnsupported.Create(Owner + '.' + Name);
end;

procedure TJ2MESiemensGame.MixInto(var Mix: TArray<Int64>; Frames: Integer);
begin
  Sweep;
  for var I := 0 to Frames - 1 do
  begin
    var Sample := Int64(0);
    if FCurrent <> nil then
    begin
      if not FCurrent.Silent then
        Sample := Round(Sin(FCurrent.Phase) * 8192);
      FCurrent.Phase := FCurrent.Phase + FCurrent.Increment;
      if FCurrent.Phase >= 2 * Pi then
        FCurrent.Phase := FCurrent.Phase - 2 * Pi;
      Dec(FCurrent.Remaining);
      if (FCurrent.Remaining = 0) and not FCurrent.NextSegment then
        StopMelody;
    end;
    if FToneRemaining > 0 then
    begin
      if not FSilentTone then
        Inc(Sample, Round(Sin(FTonePhase) * 8192));
      FTonePhase := FTonePhase + FToneIncrement;
      if FTonePhase >= 2 * Pi then
        FTonePhase := FTonePhase - 2 * Pi;
      Dec(FToneRemaining);
    end;
    Inc(Mix[I * 2], Sample);
    Inc(Mix[I * 2 + 1], Sample);
  end;
end;

procedure TJ2MESiemensGame.Shutdown;
begin
  StopMelody;
  FToneRemaining := 0;
end;

procedure TJ2MESiemensGame.TransferState(S: TJVMStateIO);
begin
  S.Tag('J2ME.Siemens.Game-1');
  begin

    var Keys := FComposers.Keys.ToArray;
    var N: Integer := Length(Keys);
    S.Count(N, 256);
    if S.Loading then
      FComposers.Clear
    else
      TArray.Sort<Integer>(Keys);
    for var I := 0 to N - 1 do
    begin
      var Key := 0;
      var P: TSiemensComposer;
      if S.Loading then
        P := TSiemensComposer.Create
      else
      begin
        Key := Keys[I];
        P := FComposers[Key];
      end;
      try
        S.Int(Key);
        S.Int(P.BPM);
        var Notes := P.Notes.ToArray;
        var Count: Integer := Length(Notes);
        S.Count(Count, 4096);
        if S.Loading then
        begin
          P.Notes.Clear;
          SetLength(Notes, Count);
        end;
        for var J := 0 to Count - 1 do
        begin
          S.Int(Notes[J].Note);
          S.Int(Notes[J].Length);
          S.Int(Notes[J].Target);
          S.Bool(Notes[J].TimedBody);
          if S.Loading then
            P.Notes.Add(Notes[J]);
        end;

        if S.Loading then
        begin
          FComposers.Add(Key, P);
          P := nil;
        end;
      finally
        if S.Loading then
          P.Free;
      end;
    end;
  end;
  begin

    var Keys := FMelodies.Keys.ToArray;
    var N: Integer := Length(Keys);
    S.Count(N, 256);
    if S.Loading then
      FMelodies.Clear
    else
      TArray.Sort<Integer>(Keys);
    for var I := 0 to N - 1 do
    begin
      var Key := 0;
      var P: TSiemensMelody;
      if S.Loading then
        P := TSiemensMelody.Create
      else
      begin
        Key := Keys[I];
        P := FMelodies[Key];
      end;
      try
        S.Int(Key);
        S.Int(P.Reference);
        S.Int(P.BPM);
        S.Int(P.Cursor);
        S.Bool(P.Rooted);
        S.Bool(P.Silent);
        S.Int64Value(P.Remaining);
        S.Int64Value(P.Remainder);
        S.RealValue(P.Phase);
        S.RealValue(P.Increment);
        var Count: Integer := Length(P.Notes);
        S.Count(Count, 4096);
        if S.Loading then
          SetLength(P.Notes, Count);
        for var J := 0 to Count - 1 do
        begin
          S.Int(P.Notes[J].Note);
          S.Int(P.Notes[J].Length);
          S.Int(P.Notes[J].Target);
          S.Bool(P.Notes[J].TimedBody);
        end;
        Count := Length(P.Repeats);
        S.Count(Count, 4096);
        if S.Loading then
          SetLength(P.Repeats, Count);
        for var J := 0 to Count - 1 do
          S.Int(P.Repeats[J]);
        Count := Length(P.RepeatActive);
        S.Count(Count, 4096);
        if S.Loading then
          SetLength(P.RepeatActive, Count);
        for var J := 0 to Count - 1 do
          S.Bool(P.RepeatActive[J]);

        if S.Loading then
        begin
          FMelodies.Add(Key, P);
          P := nil;
        end;
      finally
        if S.Loading then
          P.Free;
      end;
    end;
  end;
  S.Int64Value(FToneRemaining);
  S.RealValue(FTonePhase);
  S.RealValue(FToneIncrement);
  S.Bool(FSilentTone);
  var Current := 0;
  if FCurrent <> nil then
    Current := FCurrent.Reference;
  S.Int(Current);
  if S.Loading then
  begin
    FCurrent := nil;
    if (Current <> 0) and not FMelodies.TryGetValue(Current, FCurrent) then
      raise EReadError.Create('Invalid snapshot Siemens melody');
  end;
end;

end.

