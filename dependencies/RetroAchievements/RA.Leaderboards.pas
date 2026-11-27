unit RA.Leaderboards;

interface

{$SCOPEDENUMS ON}

uses
  RA.DefinitionLayout, RA.Memory, RA.MemoryValues, RA.Progress, RA.Trigger,
  RA.Value;

type
  TRALeaderboardState = (Inactive, Waiting, Active, Started, Canceled, Triggered, Disabled);

  TRALeaderboard = class
  private
    type
      TField = (Start, Cancel, Submit, Value, Progress);
  private
    FStart, FCancel, FSubmit: TRATrigger;
    FValue, FProgress: TRAValue;
    FValueExpression: string;
    FValueHash: Cardinal;
    FValueFromHits: Boolean;
    FState: TRALeaderboardState;
    FHasStartConditions: Boolean;
    FReferenceOrder: TArray<TField>;
  public
    constructor Create(const Expression: string);
    destructor Destroy; override;
    function EvaluateFrame(const ReadMemory: TRAMemoryRead; out Value: Integer): TRALeaderboardState;
    procedure Reset;
    procedure ClearProgress;
    procedure Disable;
    function ReferencesMemref(Memref: TRARuntimeMemref): Boolean;
    function InvalidateMemref(Memref: TRARuntimeMemref): Boolean;
    procedure WriteProgress(const IO: TRAProgressIO);
    procedure ReadProgress(const IO: TRAProgressIO);
    procedure CollectRCMemrefs(Memrefs: TRARuntimeMemrefs; Bind: Boolean = False);
    procedure MeasureDefinitionLayout(var Layout: TRADefinitionLayout);
    procedure RestoreRCMemrefs(Memrefs: TRARuntimeMemrefs);
    procedure WriteRCProgress(const IO: TRAProgressIO);
    procedure ReadRCProgress(const IO: TRAProgressIO; Apply: Boolean);
    function RCCurrentValue: Integer;
    property State: TRALeaderboardState read FState;
    property ValueExpression: string read FValueExpression;
    property ValueHash: Cardinal read FValueHash;
    property ValueFromHits: Boolean read FValueFromHits;
  end;

function RALeaderboardDefinitionPrefix(const Definition: string): string;

implementation

uses
  System.SysUtils, RA.Conditions, RA.Errors, RA.Utils;

function RALeaderboardDefinitionPrefix(const Definition: string): string;
var
  Terminator: Integer;
begin
  Terminator := Pos(#0, Definition);
  if Terminator = 0 then
    Result := Definition
  else
    Result := Copy(Definition, 1, Terminator - 1);
end;

function RCLeaderboardValueHash(const Definition: string): Cardinal;
var
  Start, Stop: Integer;
begin
  // rc_client hashes the first literal VAL: field up to the next double colon.
  Start := Pos('VAL:', Definition);
  if Start = 0 then
    Exit(0);
  Inc(Start, Length('VAL:'));
  Stop := Pos('::', Definition, Start);
  if Stop = 0 then
    Stop := Length(Definition) + 1;
  Result := RADJB2(UTF8String(Copy(Definition, Start, Stop - Start)));
end;

constructor TRALeaderboard.Create(const Expression: string);
const
  FieldNames: array[TField] of string = ('STA:', 'CAN:', 'SUB:', 'VAL:', 'PRO:');
  DuplicateErrors: array[TField] of Integer = (RAErrorDuplicatedStart, RAErrorDuplicatedCancel,
    RAErrorDuplicatedSubmit, RAErrorDuplicatedValue, RAErrorDuplicatedProgress);
  MissingErrors: array[TField.Start..TField.Value] of Integer =
    (RAErrorMissingStart, RAErrorMissingCancel, RAErrorMissingSubmit, RAErrorMissingValue);
var
  Text, Key: string;
  Position: Integer;
  Parsed: set of TField;

  procedure ReadField(Field: TField);
  var
    Definition: string;
    NextPosition: Integer;
    TriggerDefinition: TRATriggerDefinition;
  begin
    if Field in Parsed then
      raise ERAConditionError.CreateAt(RAErrorMessage(DuplicateErrors[Field]), Position, DuplicateErrors[Field]);
    Inc(Position, Length(FieldNames[Field]));
    if (Position > Length(Text)) or (Text[Position] = ':') then
      Exit;

    Definition := Copy(Text, Position);
    case Field of
      TField.Start, TField.Cancel, TField.Submit:
        begin
          TriggerDefinition := TRATriggerDefinition.ParsePrefix(Definition, NextPosition);
          case Field of
            TField.Start:
              begin
                FHasStartConditions := (Length(TriggerDefinition.Core) <> 0) or
                  (Length(TriggerDefinition.Alternatives) <> 0);
                FStart := TRATrigger.Create(TriggerDefinition);
              end;
            TField.Cancel:
              FCancel := TRATrigger.Create(TriggerDefinition);
            TField.Submit:
              FSubmit := TRATrigger.Create(TriggerDefinition);
          end;
        end;
      TField.Value:
        begin
          FValue := TRAValue.CreatePrefix(Definition, NextPosition);
          FValueExpression := Copy(Definition, 1, NextPosition - 1);
          FValueFromHits := FValue.ValueFromMeasuredHits;
        end;
      TField.Progress:
        FProgress := TRAValue.CreatePrefix(Definition, NextPosition);
    end;
    Include(Parsed, Field);
    FReferenceOrder := FReferenceOrder + [Field];
    Inc(Position, NextPosition - 1);
  end;

begin
  inherited Create;
  Text := RALeaderboardDefinitionPrefix(Expression);
  Position := 1;
  Parsed := [];
  while Position <= Length(Text) do
  begin
    Key := UpperCase(Copy(Text, Position, 4));
    for var Field := Low(TField) to High(TField) do
      if Key = FieldNames[Field] then
      begin
        ReadField(Field);
        Break;
      end;
    if (Position > Length(Text)) or (Text[Position] = '"') then
      Break;
    if Copy(Text, Position, 2) <> '::' then
      raise ERAConditionError.CreateAt(RAErrorMessage(RAErrorInvalidLeaderboardField), Position, RAErrorInvalidLeaderboardField);
    Inc(Position, 2);
  end;

  for var Field := TField.Start to TField.Value do
    if not (Field in Parsed) then
      raise ERAConditionError.CreateWithCode(RAErrorMessage(MissingErrors[Field]), MissingErrors[Field]);
  FValueHash := RCLeaderboardValueHash(Text);
  FState := TRALeaderboardState.Waiting;
end;

destructor TRALeaderboard.Destroy;
begin
  FProgress.Free;
  FValue.Free;
  FSubmit.Free;
  FCancel.Free;
  FStart.Free;
  inherited;
end;

function TRALeaderboard.EvaluateFrame(const ReadMemory: TRAMemoryRead; out Value: Integer): TRALeaderboardState;
var
  StartOK, CancelOK, SubmitOK, ValueReady: Boolean;
begin
  Value := 0;
  if FState in [TRALeaderboardState.Inactive, TRALeaderboardState.Disabled] then
    Exit(TRALeaderboardState.Inactive);

  ValueReady := FValue.UpdateMemory(ReadMemory);
  if FProgress <> nil then
    FProgress.UpdateMemory(ReadMemory, True);
  StartOK := FStart.TestFrame(ReadMemory);
  CancelOK := FCancel.TestFrame(ReadMemory);
  SubmitOK := FSubmit.TestFrame(ReadMemory);
  if not ValueReady or
    (FStart.State = TRATriggerState.Disabled) or (FCancel.State = TRATriggerState.Disabled) or
    (FSubmit.State = TRATriggerState.Disabled) then
  begin
    FState := TRALeaderboardState.Disabled;
    Exit(FState);
  end;

  case FState of
    TRALeaderboardState.Waiting, TRALeaderboardState.Canceled, TRALeaderboardState.Triggered:
      begin
        if StartOK then
          Exit(TRALeaderboardState.Inactive);
        FState := TRALeaderboardState.Active;
      end;
    TRALeaderboardState.Active:
      if StartOK and not CancelOK then
      begin
        if SubmitOK then
          FState := TRALeaderboardState.Triggered
        else if FHasStartConditions then
          FState := TRALeaderboardState.Started;
        FValue.Reset;
        if FProgress <> nil then
          FProgress.Reset;
      end;
    TRALeaderboardState.Started:
      if CancelOK then
        FState := TRALeaderboardState.Canceled
      else if SubmitOK then
        FState := TRALeaderboardState.Triggered;
  end;

  if (FState = TRALeaderboardState.Started) and (FProgress <> nil) then
    Value := RAValueAsInteger(FProgress.EvaluatePrepared)
  else if FState in [TRALeaderboardState.Started, TRALeaderboardState.Triggered] then
    Value := RAValueAsInteger(FValue.EvaluatePrepared);
  Result := FState;
end;

procedure TRALeaderboard.Reset;
begin
  FState := TRALeaderboardState.Waiting;
  FStart.Reset;
  FCancel.Reset;
  FSubmit.Reset;
  FValue.Reset;
  if FProgress <> nil then
    FProgress.Reset;
end;

procedure TRALeaderboard.ClearProgress;
begin
  FState := TRALeaderboardState.Waiting;
  FStart.ClearProgress;
  FCancel.ClearProgress;
  FSubmit.ClearProgress;
  FValue.ClearProgress;
  if FProgress <> nil then
    FProgress.ClearProgress;
end;

procedure TRALeaderboard.Disable;
begin
  FState := TRALeaderboardState.Disabled;
end;

function TRALeaderboard.ReferencesMemref(Memref: TRARuntimeMemref): Boolean;
begin
  Result := FStart.ReferencesMemref(Memref) or FCancel.ReferencesMemref(Memref) or
    FSubmit.ReferencesMemref(Memref) or FValue.ReferencesMemref(Memref);
end;

function TRALeaderboard.InvalidateMemref(Memref: TRARuntimeMemref): Boolean;

  procedure InvalidateTrigger(Trigger: TRATrigger);
  begin
    if Trigger.ReferencesMemref(Memref) then
    begin
      Trigger.Disable;
      Result := True;
    end;
  end;

begin
  Result := FValue.ReferencesMemref(Memref);
  // Each matching trigger is disabled before the runtime emits the board-level event.
  InvalidateTrigger(FStart);
  InvalidateTrigger(FCancel);
  InvalidateTrigger(FSubmit);
end;

procedure TRALeaderboard.WriteProgress(const IO: TRAProgressIO);
begin
  IO.WriteUInt(Ord(FState));
  FStart.WriteProgress(IO);
  FCancel.WriteProgress(IO);
  FSubmit.WriteProgress(IO);
  FValue.WriteProgress(IO);
  IO.WriteFlag(FProgress <> nil);
  if FProgress <> nil then
    FProgress.WriteProgress(IO);
end;

procedure TRALeaderboard.ReadProgress(const IO: TRAProgressIO);
var
  State: Cardinal;
begin
  State := IO.ReadUInt;
  if State > Cardinal(Ord(High(TRALeaderboardState))) then
    raise ERAProgressError.Create('Invalid RetroAchievements leaderboard state');
  FState := TRALeaderboardState(State);
  FStart.ReadProgress(IO);
  FCancel.ReadProgress(IO);
  FSubmit.ReadProgress(IO);
  FValue.ReadProgress(IO);
  if IO.ReadFlag <> (FProgress <> nil) then
    raise ERAProgressError.Create('Incompatible RetroAchievements leaderboard progress');
  if FProgress <> nil then
    FProgress.ReadProgress(IO);
end;

procedure TRALeaderboard.MeasureDefinitionLayout(var Layout: TRADefinitionLayout);
begin
  for var Field in FReferenceOrder do
    case Field of
      TField.Start:
        FStart.MeasureDefinitionLayout(Layout);
      TField.Cancel:
        FCancel.MeasureDefinitionLayout(Layout);
      TField.Submit:
        FSubmit.MeasureDefinitionLayout(Layout);
      TField.Value:
        FValue.MeasureDefinitionLayout(Layout);
      TField.Progress:
        begin
          Layout.AddValue;
          FProgress.MeasureDefinitionLayout(Layout);
        end;
    end;
end;

procedure TRALeaderboard.CollectRCMemrefs(Memrefs: TRARuntimeMemrefs; Bind: Boolean);
begin
  for var Field in FReferenceOrder do
    case Field of
      TField.Start:
        FStart.CollectRCMemrefs(Memrefs, Bind);
      TField.Cancel:
        FCancel.CollectRCMemrefs(Memrefs, Bind);
      TField.Submit:
        FSubmit.CollectRCMemrefs(Memrefs, Bind);
      TField.Value:
        FValue.CollectRCMemrefs(Memrefs, Bind);
      TField.Progress:
        FProgress.CollectRCMemrefs(Memrefs, Bind);
    end;
end;

procedure TRALeaderboard.RestoreRCMemrefs(Memrefs: TRARuntimeMemrefs);
begin
  FStart.RestoreRCMemrefs(Memrefs);
  FCancel.RestoreRCMemrefs(Memrefs);
  FSubmit.RestoreRCMemrefs(Memrefs);
  FValue.RestoreRCMemrefs(Memrefs);
  if FProgress <> nil then
    FProgress.RestoreRCMemrefs(Memrefs);
end;

procedure TRALeaderboard.WriteRCProgress(const IO: TRAProgressIO);
begin
  IO.WriteUInt(Ord(FState));
  FStart.WriteRCProgress(IO);
  FSubmit.WriteRCProgress(IO);
  FCancel.WriteRCProgress(IO);
  FValue.WriteRCProgress(IO);
end;

procedure TRALeaderboard.ReadRCProgress(const IO: TRAProgressIO; Apply: Boolean);
var
  State: Cardinal;
begin
  State := IO.ReadUInt and $7F;
  if State > Cardinal(Ord(High(TRALeaderboardState))) then
    raise ERAProgressError.Create('Invalid rcheevos leaderboard state');
  FStart.ReadRCProgress(IO, Apply);
  FSubmit.ReadRCProgress(IO, Apply);
  FCancel.ReadRCProgress(IO, Apply);
  FValue.ReadRCProgress(IO, Apply);
  if Apply then
    FState := TRALeaderboardState(State);
end;

function TRALeaderboard.RCCurrentValue: Integer;
begin
  Result := Integer(FValue.RCCurrentValue);
end;

end.

