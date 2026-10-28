unit GW.MGW;

interface

uses
  System.SysUtils, System.UITypes, System.Generics.Collections,
  Core.Emulation.Types, GW.Script, GW.MGW.Package, Core.Snapshots;

type
  TMGWImage = class
    Width, Height: Integer;
    Pixels: TArray<TAlphaColor>;
  end;

  TMGWObject = class
    Kind, DataName: string;
    Table, State, Picture: TScriptTable;
    Image: TMGWImage;
    Sound: TArray<SmallInt>;
    Expiration: Double;
  end;

  TMGWVoice = record
    Sound: TMGWObject;
    Position: Integer;
  end;

  TMGWConsole = class
  private
    FPackage: TMGWPackage;
    FEngine: TScriptEngine;
    FObjects: TObjectList<TMGWObject>;
    FLookup: TDictionary<TScriptObject, TMGWObject>;
    FImages: TObjectDictionary<string, TMGWImage>;
    FModules: TScriptTable;
    FSettings: TScriptTable;
    FRead, FWrite: TScriptValue;
    FBackground, FKeymap, FKeyDown, FKeyUp, FTimers, FTicker: TScriptValue;
    FInput: TEmulatorInput;
    FNow, FStartTime: Double;
    FRandom: Cardinal;
    FFrame: TEmulatorFrame;
    FSamples: TArray<SmallInt>;
    FVoices: array[0..15] of TMGWVoice;
    function KeyMapping(Button: TEmulatorButton): TScriptValue;
    function Invoke(const Name: string; const Args: TScriptValues): TScriptValues;
    function NewObject(const Kind: string): TScriptValue;
    function ReadProperty(const Args: TScriptValues): TScriptValues;
    function WriteProperty(const Args: TScriptValues): TScriptValues;
    function LoadModule(const Name: string): TScriptValue;
    function LoadImage(const Name: string): TMGWImage;
    procedure Bind(const Name: string; Target: TScriptTable);
    procedure Render;
  public
    constructor Create(Package: TMGWPackage; const SavedData: TBytes = nil);
    destructor Destroy; override;
    function SupportedButtons: TEmulatorButtons;
    procedure SetInput(const Input: TEmulatorInput);
    procedure RunFrame;
    procedure SerializeState(Archive: TStateArchive);
    function SavePersistent: TBytes;
    property Frame: TEmulatorFrame read FFrame;
    property Samples: TArray<SmallInt> read FSamples;
  end;

implementation

uses
  System.Classes, System.Math, System.DateUtils, System.Generics.Defaults,
  System.JSON, GW.Script.Builtins, GW.MGW.Modules;

function S(const Value: string): TScriptValue;
begin
  Result := TScriptValue.Str(Value);
end;

function N(Value: Double): TScriptValue;
begin
  Result := TScriptValue.Num(Value);
end;

function O(Value: TScriptObject): TScriptValue;
begin
  Result := TScriptValue.ObjectValue(Value);
end;

function Field(T: TScriptTable; const Name: string): TScriptValue;
begin
  Result := T.RawGet(S(Name));
end;

function Number(T: TScriptTable; const Name: string): Double;
begin
  var V := Field(T, Name);
  if V.Kind = skNil then
    Result := 0
  else
    Result := V.AsNumber;
end;

function BE(const Data: TBytes; P, Count: Integer): Cardinal;
begin
  if (P < 0) or (P > Length(Data) - Count) then
    raise EReadError.Create('MGW truncated image');

  Result := 0;
  for var i := 0 to Count - 1 do
    Result := (Result shl 8) or Data[P + i];
end;

constructor TMGWConsole.Create(Package: TMGWPackage; const SavedData: TBytes);
begin
  inherited Create;
  FPackage := Package;
  FObjects := TObjectList<TMGWObject>.Create;
  FLookup := TDictionary<TScriptObject, TMGWObject>.Create;
  FImages := TObjectDictionary<string, TMGWImage>.Create([doOwnsValues]);
  FEngine := TScriptEngine.Create;
  InstallScriptLibrary(FEngine);
  FModules := FEngine.NewTable;
  FSettings := FEngine.NewTable;
  FRead := FEngine.NewNative(ReadProperty);
  FWrite := FEngine.NewNative(WriteProperty);
  FStartTime := DateTimeToUnix(Now, False);
  FRandom := $12345678;
  var Sys := FEngine.NewTable;
  FEngine.Globals.Put('system', O(Sys), True);
  Sys.RawSet(S('GW_VERSION'), N($010600));
  Sys.RawSet(S('GW_VERSIONSTR'), S('1.6.0'));
  for var Name in ['loadunit', 'loadbin', 'newimage', 'newpicture', 'newtimer', 'newsound', 'init', 'now', 'splittime', 'round', 'random', 'randomize', 'inttostr', 'loadvalue', 'savevalue', 'playsound', 'stopsounds', 'inputstate', 'pausesounds', 'resumesounds', 'issoundactive', 'log', 'setbackground', 'setzoom', 'iszoomed'] do
    Bind(Name, Sys);
  if Length(SavedData) > 0 then
  begin
    if Length(SavedData) > 1024 * 1024 then
      raise EReadError.Create('MGW persistent data too large');

    var JSON := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(SavedData));
    try
      if not (JSON is TJSONObject) then
        raise EReadError.Create('MGW invalid persistent data');
      for var Pair in TJSONObject(JSON) do
      begin
        var Value: TScriptValue;
        if Pair.JsonValue is TJSONNumber then
          Value := N(TJSONNumber(Pair.JsonValue).AsDouble)
        else if Pair.JsonValue is TJSONBool then
          Value := TScriptValue.Bool(TJSONBool(Pair.JsonValue).AsBoolean)
        else if Pair.JsonValue is TJSONString then
          Value := S(Pair.JsonValue.Value)
        else
          Continue;

        FSettings.RawSet(S(Pair.JsonString.Value), Value);
      end;
    finally
      JSON.Free;
    end;
  end;
  FTicker := SV(FEngine.Run(FPackage.Script('main')));
  if FBackground.Kind = skNil then
    raise EReadError.Create('MGW main did not initialize a display');

  Render;
end;

destructor TMGWConsole.Destroy;
begin
  FEngine.Free;
  FImages.Free;
  FLookup.Free;
  FObjects.Free;
  inherited;
end;

procedure TMGWConsole.Bind(const Name: string; Target: TScriptTable);
begin
  Target.RawSet(S(Name), FEngine.NewNative(
    function(const A: TScriptValues): TScriptValues
    begin
      Result := Invoke(Name, A);
    end));
end;

function TMGWConsole.LoadModule(const Name: string): TScriptValue;
begin
  Result := FModules.RawGet(S(Name));
  if Result.Kind <> skNil then
    Exit;

  var Text := MGWModule(Name);
  if Text = '' then
    Text := FPackage.Script(Name);
  try
    Result := SV(FEngine.Run(Text));
  except
    on E: Exception do
      raise EReadError.Create('MGW unit ' + Name + ': ' + E.Message);
  end;
  FModules.RawSet(S(Name), Result);
end;

function TMGWConsole.NewObject(const Kind: string): TScriptValue;
begin
  if FObjects.Count >= 8192 then
    raise EReadError.Create('MGW object limit');

  var Obj := TMGWObject.Create;
  FObjects.Add(Obj);
  Obj.Kind := Kind;
  Obj.Table := FEngine.NewTable;
  Obj.State := FEngine.NewTable;
  Obj.State.RawSet(S('visible'), TScriptValue.Bool(True));
  Obj.State.RawSet(S('enabled'), TScriptValue.Bool(False));
  for var Name in ['left', 'top', 'layer', 'interval', 'width', 'height'] do
    Obj.State.RawSet(S(Name), N(0));
  Obj.Table.RawSet(S('$state'), O(Obj.State));
  FLookup.Add(Obj.Table, Obj);
  Obj.Table.Meta := FEngine.NewTable;
  Obj.Table.Meta.RawSet(S('__index'), FRead);
  Obj.Table.Meta.RawSet(S('__newindex'), FWrite);
  if Kind = 'image' then
  begin
    var Picture := NewObject('picture');
    Obj.Picture := TScriptTable(Picture.Obj);
    Obj.Table.RawSet(S('$picture'), Picture);
  end;
  Result := O(Obj.Table);
end;

function TMGWConsole.ReadProperty(const Args: TScriptValues): TScriptValues;
begin
  var Obj := FLookup[SV(Args).Obj];
  var Name := SV(Args, 1).AsString;
  if (Obj.Kind = 'image') and (Name = 'picture') then
    Exit(TScriptValues.Create(O(Obj.Picture)));

  if (Obj.Kind = 'image') and ((Name = 'width') or (Name = 'height')) then
  begin
    var Value := Number(Obj.State, Name);
    var Image := FLookup[Obj.Picture].Image;
    if (Value = 0) and (Image <> nil) then
      if Name = 'width' then
        Value := Image.Width
      else
        Value := Image.Height;
    Exit(TScriptValues.Create(N(Value)));
  end;

  Result := [Field(Obj.State, Name)];
end;

function TMGWConsole.WriteProperty(const Args: TScriptValues): TScriptValues;
begin
  Result := nil;
  var Obj := FLookup[SV(Args).Obj];
  var Name := SV(Args, 1).AsString;
  var Value := SV(Args, 2);
  if (Obj.Kind = 'picture') and (Name = 'data') then
  begin
    Obj.DataName := Value.AsString;
    Obj.Image := LoadImage(Obj.DataName);
    Exit;
  end;

  if (Obj.Kind = 'image') and (Name = 'picture') then
  begin
    var Picture := FLookup[Obj.Picture];
    if Value.Kind = skNil then
    begin
      Picture.Image := nil;
      Picture.DataName := '';
    end
    else
    begin
      Picture.Image := FLookup[Value.Obj].Image;
      Picture.DataName := FLookup[Value.Obj].DataName;
    end;
    Exit;
  end;

  if (Obj.Kind = 'sound') and (Name = 'data') then
  begin
    Obj.DataName := Value.AsString;
    var Data := FPackage.Read(Obj.DataName);
    SetLength(Obj.Sound, Length(Data) div 2);
    for var i := 0 to High(Obj.Sound) do
    begin
      var Bits := Word(BE(Data, i * 2, 2));
      Move(Bits, Obj.Sound[i], 2);
    end;
    Exit;
  end;

  Obj.State.RawSet(S(Name), Value);
  if (Obj.Kind = 'timer') and ((Name = 'enabled') or (Name = 'interval')) then
    Obj.Expiration := FNow + Number(Obj.State, 'interval');
end;

function TMGWConsole.LoadImage(const Name: string): TMGWImage;
begin
  if FImages.TryGetValue(Name, Result) then
    Exit;

  var Data := FPackage.Read(Name);
  var Image := TMGWImage.Create;
  try
    Image.Width := BE(Data, 0, 2);
    Image.Height := BE(Data, 2, 2);
    if (Image.Width <= 0) or (Image.Height <= 0) or (Image.Width > 4096) or (Image.Height > 4096) then
      raise EReadError.Create('MGW invalid image size ' + Name);

    SetLength(Image.Pixels, Image.Width * Image.Height);
    var Base := 8 + Image.Height * 4;
    for var Y := 0 to Image.Height - 1 do
    begin
      var Row := Base + Integer(BE(Data, 8 + Y * 4, 4));
      var P := Row + Integer(BE(Data, Row, 2)) * 2;
      var X := 0;
      while X < Image.Width do
      begin
        var Runs := Integer(BE(Data, P, 2));
        Inc(P, 2);
        if (Runs < 1) or (Runs > 8192) then
          raise EReadError.Create('MGW invalid image runs ' + Name);

        for var Run := 1 to Runs do
        begin
          var Code := Integer(BE(Data, P, 2));
          Inc(P, 2);
          var Count := Code and $1FFF;
          var Alpha := Code shr 13;
          if (Count = 0) or (Alpha > 4) or (Count > Image.Width - X + 31) then
            raise EReadError.Create('MGW invalid image span ' + Name);

          for var i := 1 to Count do
          begin
            var Color: Cardinal := 0;
            if Alpha > 0 then
            begin
              var RGB := BE(Data, P, 2);
              Inc(P, 2);
              var A: Cardinal := Alpha * 255 div 4;
              var R: Cardinal := (RGB shr 11) * 255 div 31;
              var G: Cardinal := ((RGB shr 5) and 63) * 255 div 63;
              var B: Cardinal := (RGB and 31) * 255 div 31;
              Color := (A shl 24) or ((R * A div 255) shl 16) or ((G * A div 255) shl 8) or (B * A div 255);
            end;
            if X < Image.Width then
              Image.Pixels[Y * Image.Width + X] := Color;
            Inc(X);
          end;
        end;
      end;
    end;
    FImages.Add(Name, Image);
    Result := Image;
  except
    Image.Free;
    raise;
  end;
end;

function TMGWConsole.Invoke(const Name: string; const Args: TScriptValues): TScriptValues;
begin
  Result := nil;
  var V := SV(Args);
  if Name = 'loadunit' then
    Exit(TScriptValues.Create(LoadModule(V.AsString)));

  if Name = 'loadbin' then
  begin
    if Length(FPackage.Read(V.AsString)) = 0 then
      Exit(TScriptValues.Create(TScriptValue.NilValue));

    Exit(TScriptValues.Create(V));
  end;

  if Name.StartsWith('new') then
    Exit(TScriptValues.Create(NewObject(Copy(Name, 4, MaxInt))));

  if Name = 'init' then
  begin
    if FLookup.ContainsKey(V.Obj) then
    begin
      FBackground := V;
      FKeymap := SV(Args, 1);
      FKeyDown := SV(Args, 2);
      FKeyUp := SV(Args, 3);
      FTimers := SV(Args, 4);
    end
    else
    begin
      FBackground := FEngine.Get(V, S('background'));
      FKeymap := FEngine.Get(V, S('keymap'));
      FKeyDown := FEngine.Get(V, S('keydown'));
      FKeyUp := FEngine.Get(V, S('keyup'));
      FTimers := FEngine.Get(V, S('timers'));
    end;

    Exit(TScriptValues.Create(FEngine.NewNative(
      function(const A: TScriptValues): TScriptValues
      begin
        Result := [TScriptValue.Bool(True)];
      end)));
  end;
  if Name = 'now' then
    Exit(TScriptValues.Create(N(FStartTime + Floor(FNow / 1000))));

  if Name = 'splittime' then
  begin
    var Date := UnixToDateTime(Trunc(V.AsNumber), False);
    var Y, M, D, H, Min, Sec, MS: Word;
    DecodeDateTime(Date, Y, M, D, H, Min, Sec, MS);
    Exit(TScriptValues.Create(N(H), N(Min), N(Sec), N(0), N(D), N(M), N(Y)));
  end;

  if Name = 'round' then
    Exit(TScriptValues.Create(N(Round(V.AsNumber))));

  if Name = 'randomize' then
  begin
    FRandom := Cardinal(Trunc(FStartTime + FNow)) xor $A5A5A5A5;
    if FRandom = 0 then
      FRandom := 1;
    Exit;
  end;

  if Name = 'random' then
  begin
    FRandom := FRandom xor (FRandom shl 13);
    FRandom := FRandom xor (FRandom shr 17);
    FRandom := FRandom xor (FRandom shl 5);
    var R := FRandom / 4294967296.0;
    if V.Kind = skNumber then
      R := Floor(R * V.Number);
    Exit(TScriptValues.Create(N(R)));
  end;

  if Name = 'inttostr' then
    Exit(TScriptValues.Create(S(V.AsString)));

  if Name = 'loadvalue' then
    Exit(TScriptValues.Create(FSettings.RawGet(V)));

  if Name = 'savevalue' then
  begin
    FSettings.RawSet(V, SV(Args, 1));
    Exit;
  end;

  if Name = 'playsound' then
  begin
    if (V.Kind = skNil) or not FLookup.ContainsKey(V.Obj) then
      Exit;

    var Channel := -1;
    if Length(Args) > 1 then
      Channel := Trunc(Args[1].AsNumber);
    if Channel < 0 then
      for var i := 0 to High(FVoices) do
        if FVoices[i].Sound = nil then
        begin
          Channel := i;
          Break;
        end;

    if (Channel >= 0) and (Channel <= High(FVoices)) then
    begin
      FVoices[Channel].Sound := FLookup[V.Obj];
      FVoices[Channel].Position := 0;
    end;
    Exit;
  end;

  if Name = 'stopsounds' then
  begin
    var Channel := -1;
    if V.Kind = skNumber then
      Channel := Trunc(V.Number);
    for var i := 0 to High(FVoices) do
      if (Channel < 0) or (Channel = i) then
        FVoices[i].Sound := nil;
    Exit;
  end;

  if Name = 'inputstate' then
  begin
    if V.Obj is TScriptTable then
    begin
      var Names: TArray<string> := ['up', 'down', 'left', 'right', 'a', 'b', 'l2', 'l1', 'x', 'r1', 'r2', 'y', 'start'];
      for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
        TScriptTable(V.Obj).RawSet(S(Names[Ord(Button)]), TScriptValue.Bool(Button in FInput.Buttons));
    end;
    Exit;
  end;

  if Name = 'issoundactive' then
    Exit(TScriptValues.Create(TScriptValue.Bool(True)));

  if Name = 'iszoomed' then
    Exit(TScriptValues.Create(TScriptValue.Bool(False)));

  if Name = 'setbackground' then
  begin
    FBackground := V;
    Exit;
  end;

  if (Name = 'log') or (Name = 'setzoom') or (Name = 'pausesounds') or (Name = 'resumesounds') then
    Exit;

  raise EReadError.Create('MGW unknown system function ' + Name);
end;

function TMGWConsole.KeyMapping(Button: TEmulatorButton): TScriptValue;
const
  Names: array[TEmulatorButton] of string = ('up', 'down', 'left', 'right', 'a', 'b', 'l2', 'l1', 'x', 'r1', 'r2', 'y', 'start');
begin
  Result := FEngine.Get(FKeymap, S(Names[Button]));
  if (Result.Kind = skNil) and (Button = TEmulatorButton.A) then
    Result := FEngine.Get(FKeymap, S('b'));
end;

function TMGWConsole.SupportedButtons: TEmulatorButtons;
begin
  // Polling-style scripts can read the whole input state without a keymap.
  if not (FKeymap.Obj is TScriptTable) then
    Exit([Low(TEmulatorButton)..High(TEmulatorButton)]);
  Result := [];
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    var Mapping := KeyMapping(Button);
    if not (Mapping.Obj is TScriptTable) then
      Continue;
    for var I := 1 to TScriptTable(Mapping.Obj).Count do
      if FEngine.Get(Mapping, N(I)).Kind = skNumber then
      begin
        Include(Result, Button);
        Break;
      end;
  end;
end;

procedure TMGWConsole.SetInput(const Input: TEmulatorInput);

  function Keys(const State: TEmulatorInput): TArray<Integer>;
  begin
    Result := nil;
    for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
      if Button in State.Buttons then
      begin
        var Mapping := KeyMapping(Button);
        if not (Mapping.Obj is TScriptTable) then
          Continue;

        for var i := 1 to TScriptTable(Mapping.Obj).Count do
        begin
          var Key := FEngine.Get(Mapping, N(i));
          if Key.Kind <> skNumber then
            Continue;

          var Found := False;
          for var Existing in Result do
            if Existing = Trunc(Key.Number) then
              Found := True;
          if not Found then
            Result := Result + [Integer(Trunc(Key.Number))];
        end;
      end;
  end;

  function Contains(const Values: TArray<Integer>; Value: Integer): Boolean;
  begin
    Result := False;
    for var Existing in Values do
      if Existing = Value then
        Exit(True);
  end;

begin
  FEngine.BeginFrame;
  var Previous := Keys(FInput);
  var Current := Keys(Input);
  FInput := Input;

  for var Key in Previous do
    if not Contains(Current, Key) and (FKeyUp.Kind <> skNil) then
      FEngine.Call(FKeyUp, [N(Key)]);

  for var Key in Current do
    if not Contains(Previous, Key) and (FKeyDown.Kind <> skNil) then
      FEngine.Call(FKeyDown, [N(Key)]);
end;

procedure TMGWConsole.RunFrame;
begin
  FEngine.BeginFrame;
  FNow := FNow + 1000 / 60;
  Inc(FFrame.FrameNumber);
  if FTimers.Obj is TScriptTable then
    for var i := 1 to TScriptTable(FTimers.Obj).Count do
    begin
      var TimerValue := FEngine.Get(FTimers, N(i));
      var Timer: TMGWObject;
      if FLookup.TryGetValue(TimerValue.Obj, Timer) and Field(Timer.State, 'enabled').Truth and
        (Number(Timer.State, 'interval') > 0) and (FNow >= Timer.Expiration) then
      begin
        Timer.Expiration := FNow + Number(Timer.State, 'interval');
        var Handler := Field(Timer.State, 'ontimer');
        if Handler.Kind <> skNil then
          FEngine.Call(Handler, [TimerValue]);
      end;
    end;
  if FTicker.Obj is TScriptFunction then
    FEngine.Call(FTicker, nil);
  SetLength(FSamples, 1470);
  for var Sample := 0 to 734 do
  begin
    var Mix := 0;
    for var i := 0 to High(FVoices) do
    begin
      var Voice := FVoices[i];
      if Voice.Sound <> nil then
      begin
        if Voice.Position < Length(Voice.Sound.Sound) then
        begin
          Inc(Mix, Voice.Sound.Sound[Voice.Position]);
          Inc(FVoices[i].Position);
        end
        else
          FVoices[i].Sound := nil;
      end;
    end;
    FSamples[Sample * 2] := EnsureRange(Mix, -32768, 32767);
    FSamples[Sample * 2 + 1] := FSamples[Sample * 2];
  end;
  Render;
  var Roots: TScriptValues := [O(FModules), O(FSettings), FBackground, FKeymap, FKeyDown, FKeyUp, FTimers, FTicker, FRead, FWrite];
  for var Voice in FVoices do
    if Voice.Sound <> nil then
      Roots := Roots + [O(Voice.Sound.Table)];
  FEngine.Collect(Roots);
  for var i := FObjects.Count - 1 downto 0 do
    if not FEngine.IsAlive(FObjects[i].Table) then
    begin
      FLookup.Remove(FObjects[i].Table);
      FObjects.Delete(i);
    end;
end;

procedure TMGWConsole.Render;
begin
  var Background := FLookup[FBackground.Obj];
  var Image := FLookup[Background.Picture].Image;
  if Image = nil then
    raise EReadError.Create('MGW missing background image');

  FFrame.Width := Image.Width;
  FFrame.Height := Image.Height;
  FFrame.FramesPerSecond := 60;
  SetLength(FFrame.Pixels, Image.Width * Image.Height);

  // Publish independent buffers; previous frames may still be displayed.
  FFrame.Pixels := Copy(Image.Pixels);
  var Sprites := TList<TMGWObject>.Create;
  try
    for var Obj in FObjects do
      if (Obj.Kind = 'image') and (Obj <> Background) and Field(Obj.State, 'visible').Truth then
        Sprites.Add(Obj);
    Sprites.Sort(TComparer<TMGWObject>.Construct(
      function(const A, B: TMGWObject): Integer
      begin
        Result := CompareValue(Number(A.State, 'layer'), Number(B.State, 'layer'));
        if Result = 0 then
          Result := FObjects.IndexOf(A) - FObjects.IndexOf(B);
      end));
    var BX := Round(Number(Background.State, 'left'));
    var BY := Round(Number(Background.State, 'top'));
    for var Obj in Sprites do
    begin
      var Source := FLookup[Obj.Picture].Image;
      if Source = nil then
        Continue;

      var Left := Round(Number(Obj.State, 'left')) - BX;
      var Top := Round(Number(Obj.State, 'top')) - BY;
      for var Y := Max(0, -Top) to Min(Source.Height - 1, FFrame.Height - Top - 1) do
        for var X := Max(0, -Left) to Min(Source.Width - 1, FFrame.Width - Left - 1) do
        begin
          var P := (Y + Top) * FFrame.Width + Left + X;
          var Src := Source.Pixels[Y * Source.Width + X];
          var Dst := FFrame.Pixels[P];
          var Inv: Cardinal := 255 - (Src shr 24);
          FFrame.Pixels[P] := $FF000000 or
            (Min(Cardinal(255), ((Src shr 16) and 255) + ((Dst shr 16) and 255) * Inv div 255) shl 16) or
            (Min(Cardinal(255), ((Src shr 8) and 255) + ((Dst shr 8) and 255) * Inv div 255) shl 8) or
            Min(Cardinal(255), (Src and 255) + (Dst and 255) * Inv div 255);
        end;
    end;
  finally
    Sprites.Free;
  end;
end;

procedure TMGWConsole.SerializeState(Archive: TStateArchive);

  procedure Text(var Value: string);
  begin
    var Bytes: TBytes;
    if not Archive.Loading then
      Bytes := TEncoding.UTF8.GetBytes(Value);
    var Size := Length(Bytes);
    Archive.Field(Size, SizeOf(Size));
    if (Size < 0) or (Size > 4096) then
      raise EReadError.Create('MGW snapshot resource name limit');

    SetLength(Bytes, Size);
    if Size > 0 then
      Archive.Field(Bytes[0], Size);
    if Archive.Loading then
      Value := TEncoding.UTF8.GetString(Bytes);
  end;

begin
  FEngine.SerializeState(Archive);
  FEngine.TransferTable(Archive, FModules);
  FEngine.TransferTable(Archive, FSettings);
  FEngine.TransferValue(Archive, FBackground);
  FEngine.TransferValue(Archive, FKeymap);
  FEngine.TransferValue(Archive, FKeyDown);
  FEngine.TransferValue(Archive, FKeyUp);
  FEngine.TransferValue(Archive, FTimers);
  FEngine.TransferValue(Archive, FTicker);
  FEngine.TransferValue(Archive, FRead);
  FEngine.TransferValue(Archive, FWrite);
  Archive.Field(FInput, SizeOf(FInput));
  Archive.Field(FNow, SizeOf(FNow));
  Archive.Field(FStartTime, SizeOf(FStartTime));
  Archive.Field(FRandom, SizeOf(FRandom));
  Archive.Field(FFrame.FrameNumber, SizeOf(FFrame.FrameNumber));

  if IsNan(FNow) or IsInfinite(FNow) or (FNow < 0) or IsNan(FStartTime) or IsInfinite(FStartTime) then
    raise EReadError.Create('MGW invalid snapshot time');

  var Count := FObjects.Count;
  Archive.Field(Count, SizeOf(Count));

  if (Count < 0) or (Count > 8192) then
    raise EReadError.Create('MGW invalid host object count');

  if Archive.Loading then
  begin
    FLookup.Clear;
    FObjects.Clear;
    for var i := 1 to Count do
      FObjects.Add(TMGWObject.Create);
  end;
  for var Obj in FObjects do
  begin
    Text(Obj.Kind);
    FEngine.TransferTable(Archive, Obj.Table);
    FEngine.TransferTable(Archive, Obj.State);
    FEngine.TransferTable(Archive, Obj.Picture);
    Text(Obj.DataName);
    Archive.Field(Obj.Expiration, SizeOf(Obj.Expiration));

    if IsNan(Obj.Expiration) or IsInfinite(Obj.Expiration) then
      raise EReadError.Create('MGW invalid timer expiration');

    if Archive.Loading then
    begin
      FLookup.Add(Obj.Table, Obj);
      if Obj.Kind = 'picture' then
      begin
        Obj.Image := nil;
        if Obj.DataName <> '' then
          Obj.Image := LoadImage(Obj.DataName);
      end;
      if Obj.Kind = 'sound' then
      begin
        var Data := FPackage.Read(Obj.DataName);
        SetLength(Obj.Sound, Length(Data) div 2);
        for var i := 0 to High(Obj.Sound) do
        begin
          var Bits := Word(BE(Data, i * 2, 2));
          Move(Bits, Obj.Sound[i], 2);
        end;
      end;
    end;
  end;
  for var i := 0 to High(FVoices) do
  begin
    var Index := -1;
    if not Archive.Loading then
      Index := FObjects.IndexOf(FVoices[i].Sound);
    Archive.Field(Index, SizeOf(Index));
    Archive.Field(FVoices[i].Position, SizeOf(FVoices[i].Position));

    if (Index < -1) or (Index >= FObjects.Count) or (FVoices[i].Position < 0) then
      raise EReadError.Create('MGW invalid audio voice');

    if Archive.Loading then
    begin
      FVoices[i].Sound := nil;
      if Index >= 0 then
      begin
        if FObjects[Index].Kind <> 'sound' then
          raise EReadError.Create('MGW invalid sound reference');

        FVoices[i].Sound := FObjects[Index];
      end;
    end;
  end;
  if Archive.Loading then
  begin
    FSamples := nil;
    FEngine.BeginFrame;
    Render;
  end;
end;

function TMGWConsole.SavePersistent: TBytes;
begin
  var JSON := TJSONObject.Create;
  try
    for var E in FSettings.Entries.Values do
      case E.Value.Kind of
        skNumber:
          JSON.AddPair(E.Key.AsString, TJSONNumber.Create(E.Value.Number));
        skBool:
          JSON.AddPair(E.Key.AsString, TJSONBool.Create(E.Value.Truth));
        skString:
          JSON.AddPair(E.Key.AsString, E.Value.Text);
      end;
    Result := TEncoding.UTF8.GetBytes(JSON.ToJSON);
  finally
    JSON.Free;
  end;
end;

end.

