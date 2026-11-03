program RecognitionTest;

{$APPTYPE CONSOLE}

// Recognition must keep trying after another platform rejects an image, but
// retain the original error when nothing matches and never swallow a cancel.
uses
  System.SysUtils, System.Classes, Core.EmulatorRegistry, Core.Platforms,
  Core.Emulation;

type
  TScenario = (Found, NotFound, CancelFirst, CancelLast, Ambiguous);
  TProbeError = class(EReadError)
    destructor Destroy; override;
  end;

var
  Scenario: TScenario;
  ErrorsMade, ErrorsFreed, TargetCalls, LastCalls: Integer;

destructor TProbeError.Destroy;
begin
  Inc(ErrorsFreed);
  inherited;
end;

function NewMatch(const Id: string): TCoreMatch;
begin
  Result := TCoreMatch.Create(Id,
    function: IEmulationCore
    begin
      Result := nil; // Recognition only; no machine is needed.
    end);
end;

function FirstProbe(Context: TCoreLoadContext): TCoreMatch;
begin
  if not Context.IsDiscSource then
    Context.Stream.Position := Context.Stream.Size;
  if Scenario = CancelFirst then
    raise EAbort.Create('cancel first');
  Inc(ErrorsMade);
  raise TProbeError.Create('first media error');
end;

function TargetProbe(Context: TCoreLoadContext): TCoreMatch;
begin
  Inc(TargetCalls);
  Result := nil;
  if Context.Stream.Position <> 3 then
    raise Exception.Create('Probe changed the next source probe''s position');
  if Scenario <> NotFound then
    Result := NewMatch('test-target');
end;

function LastProbe(Context: TCoreLoadContext): TCoreMatch;
begin
  Inc(LastCalls);
  if Scenario = CancelLast then
    raise EAbort.Create('cancel last');
  if Scenario = Ambiguous then
    Exit(NewMatch('test-last'));
  Inc(ErrorsMade);
  raise TProbeError.Create('last media error');
end;

procedure AddPlatform(const Id: string; const Probe: TCoreRecognizer);
begin
  TPlatformRegistry.RegisterPlatform(Id, Id, Id, 'Test', Id, Id, [Id],
    ['.iso'], Id, Id, 1);
  var Registration := TEmulationCoreRegistration.Create(Id, []);
  Registration.Add(TCoreLoadStage.Source, 10, Probe);
  Registration.AddDiscPlatform(Id, Probe);
  RegisterEmulationCore(Registration);
end;

procedure Check(Disc: Boolean; Run: TScenario);
begin
  Scenario := Run;
  ErrorsMade := 0;
  ErrorsFreed := 0;
  TargetCalls := 0;
  LastCalls := 0;
  var Stream := TBytesStream.Create(TBytes.Create(1, 2, 3, 4, 5, 6, 7, 8));
  Stream.Position := 3;
  var Name := 'test.rom';
  var Platform := '';
  if Disc then
  begin
    Name := 'test.iso';
    // An explicit optical target bypasses Source and uses AddDiscPlatform.
    if Run <> Ambiguous then
      Platform := 'test-target'
    else
      Platform := 'test-missing';
  end;
  var Context := TCoreLoadContext.Create(Stream, nil, Name);
  try
    var Outcome := '';
    try
      // Optical probes do not currently promise to restore the stream. The
      // throwing test probe consumes nothing there; Source must restore it.
      var Match := ResolveEmulationCore(Context, Platform);
      try
        if Match = nil then
          Outcome := 'nil'
        else
          Outcome := Match.PlatformId;
      finally
        Match.Free;
      end;
    except
      on E: EAbort do
        Outcome := E.Message;
      on E: ECoreSelectionRequired do
        Outcome := 'ambiguous';
      on E: TProbeError do
        Outcome := E.Message;
    end;
    var Want := '';
    case Run of
      Found: Want := 'test-target';
      NotFound: Want := 'first media error';
      CancelFirst: Want := 'cancel first';
      CancelLast: Want := 'cancel last';
      Ambiguous: if Disc then Want := 'nil' else Want := 'ambiguous';
    end;
    if Outcome <> Want then
      raise Exception.CreateFmt('disc=%s scenario=%d: %s <> %s',
        [BoolToStr(Disc, True), Ord(Run), Outcome, Want]);
    if (Run = CancelFirst) and ((TargetCalls <> 0) or (LastCalls <> 0)) then
      raise Exception.Create('Cancellation did not stop probing');
    if (Run <> CancelFirst) and ((TargetCalls <> 1) or (LastCalls <> 1)) then
      raise Exception.Create('A rejecting probe prevented the other probes');
    if ErrorsMade <> ErrorsFreed then
      raise Exception.Create('Saved probe exceptions were not freed exactly once');
    if not Disc and (Stream.Position <> 3) then
      raise Exception.Create('Source probe did not restore the stream');
  finally
    Context.Free;
    Stream.Free;
  end;
end;

begin
  try
    AddPlatform('test-first', FirstProbe);
    AddPlatform('test-target', TargetProbe);
    AddPlatform('test-last', LastProbe);
    for var Run := Low(TScenario) to High(TScenario) do
      Check(False, Run);
    Writeln('Source recognition: rejecting probes, original errors, cancellation, ambiguity and ownership OK');
    // The disc path uses the same probes, without a source position contract.
    for var Run := Low(TScenario) to Pred(High(TScenario)) do
      Check(True, Run);
    Writeln('Explicit disc recognition: rejecting probes, original errors, cancellation and ownership OK');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
