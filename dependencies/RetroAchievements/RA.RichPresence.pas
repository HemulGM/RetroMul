unit RA.RichPresence;

interface

{$SCOPEDENUMS ON}

uses
  System.Generics.Collections, RA.Conditions, RA.DefinitionLayout, RA.Format,
  RA.Memory, RA.MemoryValues, RA.Progress, RA.Trigger, RA.Value;

type
  ERARichPresenceError = class(ERAConditionError)
  private
    FLine: Integer;
  public
    constructor CreateAtLine(const Error: ERAConditionError; Line: Integer);
    property Line: Integer read FLine;
  end;

  TRARichPresence = class
  private
    type
      TPartKind = (Text, Formatted, Lookup, ASCIIChar, UnicodeChar);

      TRange = record
        First, Last: Cardinal;
        Text: string;
        TextSlot: Integer;
        Children: array[Boolean] of Integer;
      end;

      TMacro = class
      private
      // Range indices are one-based. Zero represents an empty branch.
        FRoot: Integer;
      public
        Kind: TPartKind;
        ValueFormat: TRAValueFormat;
        Ranges: TList<TRange>;
        DefaultText: string;
        NameSlot, DefaultTextSlot: Integer;
        destructor Destroy; override;
        procedure AddRange(const Range: TRange);
        procedure BalanceRanges;
        function Lookup(Value: Cardinal): string;
      end;

      TExpression = class
      public
        Evaluator: TRAValue;
        NameHash: Cardinal;
        NameSlot: Integer;
        CompiledDefinition: string;
        RestoredRCVariable: Boolean;
        constructor Create(const Definition: string);
        destructor Destroy; override;
      end;

      TPart = record
        Kind: TPartKind;
        Text: string;
        TextSlot: Integer;
        UnknownMacro: Boolean;
        ValueFormat: TRAValueFormat;
        Macro: TMacro;
        Expression: TExpression;
        PreparedExpression: TExpression;
      end;

      TDisplay = class
      public
        Condition: TRATrigger;
        HasRequiredHits: Boolean;
        Parts: TArray<TPart>;
        destructor Destroy; override;
        function Render: string;
      end;
  private
    FMacros: TObjectDictionary<string, TMacro>;
    FMacroOrder: TList<TMacro>;
    FExpressions: TObjectDictionary<string, TExpression>;
    FSimpleExpressions: TDictionary<string, TExpression>;
    FPreparedExpressions: TObjectDictionary<string, TExpression>;
    FDisplays: TObjectList<TDisplay>;
    FRCVariables: TList<TExpression>;
    FConditionsPrepared: Boolean;
    FDefinitionLayout: TRADefinitionLayout;
    FDefinitionStrings: TRADefinitionStrings;
    FDefinitionLinesRead: Integer;
    function ParseParts(const Line: string): TArray<TPart>;
    function FindMacro(const Name: string; out Macro: TMacro): Boolean;
    function ParseExpression(const Name, Text: string; out Prepared: TExpression): TExpression;
    procedure ResolveDefinitionStrings;
    procedure ParseDisplay(const Line: string; Conditional: Boolean);
    procedure ParseScript(const Script: string; out ErrorLine: Integer);
    function RenderDisplay(EvaluateConditions: Boolean): string;
  public
    constructor Create(const Script: string);
    destructor Destroy; override;
    procedure UpdateFrame(const ReadMemory: TRAMemoryRead);
    function GetDisplayString: string; overload;
    function GetDisplayString(Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt; overload;
    function PreviewDisplayString: string;
    function EvaluateFrame(const ReadMemory: TRAMemoryRead): string; overload;
    function EvaluateFrame(const ReadMemory: TRAMemoryRead; Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt; overload;
    procedure Reset;
    procedure ClearProgress;
    procedure WriteProgress(const IO: TRAProgressIO);
    procedure ReadProgress(const IO: TRAProgressIO);
    procedure CollectRCMemrefs(Memrefs: TRARuntimeMemrefs; Bind: Boolean = False);
    procedure RestoreRCMemrefs(Memrefs: TRARuntimeMemrefs);
    function GetDefinitionLayout: TRADefinitionLayout;
    property DefinitionLinesRead: Integer read FDefinitionLinesRead;
    function HasRCConditions: Boolean;
    procedure WriteRCConditions(const IO: TRAProgressIO);
    procedure ReadRCConditions(const IO: TRAProgressIO; Apply: Boolean);
    procedure ResetRCConditions;
    function HasRCVariables: Boolean;
    procedure WriteRCVariables(const IO: TRAProgressIO);
    procedure ReadRCVariables(const IO: TRAProgressIO; Apply: Boolean);
    function RestoreRCDisplay: string;
  end;

function RARichPresenceScriptPrefix(const Script: string): string;

implementation

uses
  System.StrUtils, System.SysUtils, RA.Errors, RA.Streams, RA.Utils;

constructor ERARichPresenceError.CreateAtLine(const Error: ERAConditionError; Line: Integer);
begin
  if Error.Position > 0 then
    inherited CreateAt(Error.Reason, Error.Position, Error.Code)
  else
    inherited CreateWithCode(Error.Message, Error.Code);
  FLine := Line;
end;

function RARichPresenceScriptPrefix(const Script: string): string;
begin
  var Terminator := Pos(#0, Script);
  if Terminator = 0 then
    Result := Script
  else
    Result := Copy(Script, 1, Terminator - 1);
end;

procedure TRARichPresence.CollectRCMemrefs(Memrefs: TRARuntimeMemrefs; Bind: Boolean);
begin
  for var Display in FDisplays do
  begin
    for var Part in Display.Parts do
    begin
      if (Part.PreparedExpression <> nil) and (Part.PreparedExpression <> Part.Expression) then
        Part.PreparedExpression.Evaluator.CollectRCMemrefs(Memrefs, Bind);
      if Part.Expression <> nil then
        Part.Expression.Evaluator.CollectRCMemrefs(Memrefs, Bind);
    end;
    if Display.Condition <> nil then
      Display.Condition.CollectRCMemrefs(Memrefs, Bind);
  end;
end;

procedure TRARichPresence.RestoreRCMemrefs(Memrefs: TRARuntimeMemrefs);
begin
  for var Expression in FExpressions.Values do
    Expression.Evaluator.RestoreRCMemrefs(Memrefs);
  for var Expression in FPreparedExpressions.Values do
    Expression.Evaluator.RestoreRCMemrefs(Memrefs);
  for var Display in FDisplays do
    if Display.Condition <> nil then
      Display.Condition.RestoreRCMemrefs(Memrefs);
end;

function TRARichPresence.HasRCVariables: Boolean;
begin
  Result := FRCVariables.Count <> 0;
end;

function TRARichPresence.HasRCConditions: Boolean;
begin
  Result := (FDisplays.Count > 1) and (FDisplays[0].Condition <> nil);
end;

procedure TRARichPresence.WriteRCVariables(const IO: TRAProgressIO);
begin
  IO.WriteUInt(FRCVariables.Count);
  for var Variable in FRCVariables do
  begin
    IO.WriteUInt(Variable.NameHash);
    Variable.Evaluator.WriteRCProgress(IO);
  end;
end;

procedure TRARichPresence.ReadRCVariables(const IO: TRAProgressIO; Apply: Boolean);
const
  HasConditions = $01000000;
var
  Pending: TList<TExpression>;
  Count, NameHash, Flags: Cardinal;
  KnownIndex: Integer;
begin
  Count := IO.ReadUInt;
  if (Count = 0) or (FRCVariables.Count = 0) then
    Exit;
  if UInt64(Count) * 16 > UInt64(IO.Remaining) then
    raise ERAProgressError.Create('Invalid rcheevos Rich Presence variable count');

  Pending := TList<TExpression>.Create;
  try
    Pending.AddRange(FRCVariables);
    for var Index := 0 to Integer(Count) - 1 do
    begin
      NameHash := IO.ReadUInt;
      KnownIndex := -1;
      for var I := 0 to Pending.Count - 1 do
        if Pending[I].NameHash = NameHash then
        begin
          KnownIndex := I;
          Break;
        end;
      if KnownIndex >= 0 then
      begin
        Pending[KnownIndex].Evaluator.ReadRCProgress(IO, Apply);
        if Apply then
          Pending[KnownIndex].RestoredRCVariable := True;
        Pending.Delete(KnownIndex);
      end
      else
      begin
        Flags := IO.ReadUInt;
        IO.ReadUInt;
        IO.ReadUInt;
        // A variable's condition data has no size field. Its definition establishes its length.
        if (Flags and HasConditions) <> 0 then
          Break;
      end;
    end;
    if Apply then
      for var Variable in Pending do
      begin
        Variable.Evaluator.Reset;
        // A present VARS section defines missing variables as reset.
        Variable.RestoredRCVariable := True;
      end;
  finally
    Pending.Free;
  end;
end;

procedure TRARichPresence.WriteRCConditions(const IO: TRAProgressIO);
begin
  for var Display in FDisplays do
    if Display.Condition <> nil then
      Display.Condition.WriteRCProgress(IO);
end;

procedure TRARichPresence.ReadRCConditions(const IO: TRAProgressIO; Apply: Boolean);
begin
  for var Display in FDisplays do
    if Display.Condition <> nil then
      Display.Condition.ReadRCProgress(IO, Apply);
end;

procedure TRARichPresence.ResetRCConditions;
begin
  for var Display in FDisplays do
    if Display.Condition <> nil then
      Display.Condition.Reset;
end;

function TRARichPresence.RestoreRCDisplay: string;
begin
  for var Expression in FExpressions.Values do
  begin
    // Older RetroMul snapshots could omit a variable for a single Measured with supporting conditions.
    Expression.Evaluator.RestoreRCDisplayValue(not Expression.RestoredRCVariable);
    Expression.RestoredRCVariable := False;
  end;
  FConditionsPrepared := False;
  Result := PreviewDisplayString;
end;

destructor TRARichPresence.TMacro.Destroy;
begin
  Ranges.Free;
  inherited;
end;

procedure TRARichPresence.TMacro.AddRange(const Range: TRange);
var
  Node, Parent: Integer;
  ToRight: Boolean;
  Existing: TRange;
begin
  Node := FRoot;
  Parent := 0;
  ToRight := False;
  while Node <> 0 do
  begin
    Existing := Ranges[Node - 1];
    if Range.First > Existing.Last then
    begin
      if (Range.First = Existing.Last + 1) and (Range.Text = Existing.Text) then
      begin
        Existing.Last := Range.Last;
        Ranges[Node - 1] := Existing;
        Exit;
      end;
      ToRight := True;
    end
    else if Range.Last < Existing.First then
    begin
      if (Range.Last = Existing.First - 1) and (Range.Text = Existing.Text) then
      begin
        Existing.First := Range.First;
        Ranges[Node - 1] := Existing;
        Exit;
      end;
      ToRight := False;
    end
    else
      raise ERAConditionError.CreateWithCode('Overlapping lookup range', RAErrorDuplicatedValue);

    Parent := Node;
    Node := Existing.Children[ToRight];
  end;

  Ranges.Add(Range);
  if Parent = 0 then
    FRoot := Ranges.Count
  else
  begin
    Existing := Ranges[Parent - 1];
    Existing.Children[ToRight] := Ranges.Count;
    Ranges[Parent - 1] := Existing;
  end;
end;

procedure TRARichPresence.TMacro.BalanceRanges;
var
  Order, Stack: TArray<Integer>;
  Node, Depth, Count: Integer;

  function Rebuild(First, Last: Integer): Integer;
  var
    Middle: Integer;
    Range: TRange;
  begin
    if First > Last then
      Exit(0);
    Middle := First + (Last - First) div 2;
    Result := Order[Middle];
    Range := Ranges[Result - 1];
    Range.Children[False] := Rebuild(First, Middle - 1);
    Range.Children[True] := Rebuild(Middle + 1, Last);
    Ranges[Result - 1] := Range;
  end;

begin
  if Ranges.Count < 3 then
    Exit;
  SetLength(Order, Ranges.Count);
  SetLength(Stack, Ranges.Count);
  Node := FRoot;
  Depth := 0;
  Count := 0;
  while (Node <> 0) or (Depth > 0) do
  begin
    while Node <> 0 do
    begin
      Stack[Depth] := Node;
      Inc(Depth);
      Node := Ranges[Node - 1].Children[False];
    end;
    Dec(Depth);
    Node := Stack[Depth];
    Order[Count] := Node;
    Inc(Count);
    Node := Ranges[Node - 1].Children[True];
  end;
  FRoot := Rebuild(0, Count - 1);
end;

function TRARichPresence.TMacro.Lookup(Value: Cardinal): string;
var
  Node: Integer;
  Range: TRange;
begin
  Node := FRoot;
  while Node <> 0 do
  begin
    Range := Ranges[Node - 1];
    if Value > Range.Last then
      Node := Range.Children[True]
    else if Value < Range.First then
      Node := Range.Children[False]
    else
      Exit(Range.Text);
  end;
  Result := DefaultText;
end;

constructor TRARichPresence.TExpression.Create(const Definition: string);
var
  NextPosition: Integer;
begin
  inherited Create;
  Evaluator := TRAValue.CreatePrefix(Definition, NextPosition, True);
  CompiledDefinition := Copy(Definition, 1, NextPosition - 1);
  // Rich Presence copies the value memory references from a separate parser.
  Evaluator.ValidateRCModifiedOperands;
  Evaluator.RestoreRCDisplayValue;
end;

destructor TRARichPresence.TExpression.Destroy;
begin
  Evaluator.Free;
  inherited;
end;

destructor TRARichPresence.TDisplay.Destroy;
begin
  Condition.Free;
  inherited;
end;

function TRARichPresence.TDisplay.Render: string;
var
  Builder: TStringBuilder;
  Part: TPart;
  CharKind: TPartKind;
  Code: Cardinal;
  Index: Integer;
begin
  Builder := TStringBuilder.Create;
  try
    Index := 0;
    while Index < Length(Parts) do
    begin
      Part := Parts[Index];
      case Part.Kind of
        TPartKind.Text:
          Builder.Append(Part.Text);
        TPartKind.Formatted:
          Builder.Append(FormatRAValue(Part.Expression.Evaluator.CurrentValue, Part.ValueFormat));
        TPartKind.Lookup:
          Builder.Append(Part.Macro.Lookup(Cardinal(RAValueAsInteger(Part.Expression.Evaluator.CurrentValue))));
        TPartKind.ASCIIChar, TPartKind.UnicodeChar:
          begin
            CharKind := Part.Kind;
            Code := Cardinal(RAValueAsInteger(Part.Expression.Evaluator.CurrentValue));
            if Code = 0 then
            begin
              repeat
                Inc(Index);
              until (Index >= Length(Parts)) or (Parts[Index].Kind <> CharKind);
              Continue;
            end;
            if CharKind = TPartKind.ASCIIChar then
            begin
              if (Code < 32) or (Code >= 127) then
                Code := Ord('?');
            end
            else if (Code < 32) or (Code > 65535) or ((Code >= $D800) and (Code <= $DFFF)) then
              Code := $FFFD;
            Builder.Append(Char(Code));
          end;
      end;
      Inc(Index);
    end;
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

function ReadScriptLine(const Line: string): string;
var
  Last: Integer;
begin
  for var Index := 1 to Length(Line) - 1 do
    if (Line[Index] = '/') and (Line[Index + 1] = '/') and ((Index = 1) or (Line[Index - 1] <> '\')) then
    begin
      Last := Index - 1;
      while (Last > 0) and CharInSet(Line[Last], [#9..#13, ' ']) do
        Dec(Last);
      Exit(Copy(Line, 1, Last));
    end;
  Last := Length(Line);
  if (Last > 0) and (Line[Last] = #13) then
    Exit(Copy(Line, 1, Last - 1));
  Result := Line;
end;

function ReadLookupNumber(const Line: string; var Index: Integer): Cardinal;
var
  Radix: Cardinal;
  Value: UInt64;
begin
  Radix := 10;
  if (Index < Length(Line)) and (Line[Index] = '0') and (Line[Index + 1] = 'x') then
  begin
    Radix := 16;
    Inc(Index, 2);
  end;

  if not TryReadRAUnsignedLong(Line, Index, Radix, Value) then
    Exit(0);
  Result := Cardinal(Value and High(Cardinal));
end;

procedure ParseLookupLine(Macro: TRARichPresence.TMacro; const Line: string; var Layout: TRADefinitionLayout; Strings: TRADefinitionStrings);
var
  EqualsAt, Index, PreviousCount: Integer;
  Range: TRARichPresence.TRange;
begin
  EqualsAt := Pos('=', Line);
  if EqualsAt = 0 then
    raise ERAConditionError.CreateWithCode('Missing lookup value', RAErrorMissingValue);
  if (EqualsAt = 2) and (Line[1] = '*') then
  begin
    Macro.DefaultText := Copy(Line, 3);
    Macro.DefaultTextSlot := Strings.AddText(Layout, Macro.DefaultText);
    Exit;
  end;

  Range := Default(TRARichPresence.TRange);
  Range.Text := Copy(Line, EqualsAt + 1);
  Index := 1;
  repeat
    Range.First := ReadLookupNumber(Line, Index);
    Range.Last := Range.First;
    if (Index < EqualsAt) and (Line[Index] = '-') then
    begin
      Inc(Index);
      Range.Last := ReadLookupNumber(Line, Index);
    end;
    while (Index < EqualsAt) and (Line[Index] = ' ') do
      Inc(Index);
    if (Index > EqualsAt) or not CharInSet(Line[Index], [',', '=']) then
      raise ERAConditionError.CreateWithCode('Invalid lookup key', RAErrorInvalidConstantOperand);
    PreviousCount := Macro.Ranges.Count;
    Macro.AddRange(Range);
    if Macro.Ranges.Count <> PreviousCount then
    begin
      Layout.AddLookupItem;
      // AddRange may merge adjacent ranges, so associate the shared label only
      // with a newly allocated entry, in the same order as the C parser.
      var AddedRange := Macro.Ranges.Last;
      AddedRange.TextSlot := Strings.AddText(Layout, Range.Text);
      Macro.Ranges[Macro.Ranges.Count - 1] := AddedRange;
    end;
    if Index = EqualsAt then
      Break;
    Inc(Index);
  until False;
end;

function TryBuiltinFormat(const Name: string; out ValueFormat: TRAValueFormat): Boolean;
begin
  if Name = 'Number' then
    ValueFormat := TRAValueFormat.Value
  else if Name = 'Centiseconds' then
    ValueFormat := TRAValueFormat.Centiseconds
  else if Name = 'Seconds' then
    ValueFormat := TRAValueFormat.Seconds
  else if Name = 'SecondsAsMinutes' then
    ValueFormat := TRAValueFormat.SecondsAsMinutes
  else if Name = 'Unformatted' then
    ValueFormat := TRAValueFormat.Unformatted
  else if (Name = 'Score') or (Name = 'Minutes') or (Name = 'Unsigned') or
    ((Length(Name) = 6) and
    ((Name.StartsWith('Float') and CharInSet(Name[6], ['1'..'6'])) or
    (Name.StartsWith('Fixed') and CharInSet(Name[6], ['1'..'3'])))) then
    ValueFormat := ParseRAFormat(UpperCase(Name))
  else
    Exit(False);
  Result := True;
end;

function TRARichPresence.ParseParts(const Line: string): TArray<TPart>;
var
  Parts: TList<TPart>;
  Part: TPart;
  Name, Definition: string;
  Index, TextStart, OpenParen, CloseParen: Integer;
begin
  if Line = '' then
    raise ERAConditionError.CreateWithCode('Missing Rich Presence display text', RAErrorMissingDisplayString);

  Parts := TList<TPart>.Create;
  try
    Index := 1;
    while Index <= Length(Line) do
    begin
      TextStart := Index;
      while Index <= Length(Line) do
      begin
        if (Line[Index] = '@') and ((Index = TextStart) or (Line[Index - 1] <> '\')) then
          Break;
        Inc(Index);
      end;
      if Index > TextStart then
      begin
        FDefinitionLayout.AddDisplayPart;
        Part := Default(TPart);
        Part.TextSlot := FDefinitionStrings.AddText(FDefinitionLayout,
          Copy(Line, TextStart, Index - TextStart), True);
        Parts.Add(Part);
      end;
      if Index > Length(Line) then
        Break;

      OpenParen := PosEx('(', Line, Index + 1);
      if OpenParen = 0 then
        raise ERAConditionError.CreateWithCode('Missing Rich Presence macro parameter', RAErrorMissingValue);
      CloseParen := PosEx(')', Line, OpenParen + 1);
      FDefinitionLayout.AddDisplayPart;
      Part := Default(TPart);
      if CloseParen = 0 then
      begin
        Part.TextSlot := FDefinitionStrings.AddText(FDefinitionLayout, Copy(Line, Index));
        Parts.Add(Part);
        Break;
      end;

      Name := Copy(Line, Index + 1, OpenParen - Index - 1);
      if FindMacro(Name, Part.Macro) then
      begin
        Part.Kind := Part.Macro.Kind;
        Part.ValueFormat := Part.Macro.ValueFormat;
      end
      else if Name = 'ASCIIChar' then
        Part.Kind := TPartKind.ASCIIChar
      else if Name = 'UnicodeChar' then
        Part.Kind := TPartKind.UnicodeChar
      else if TryBuiltinFormat(Name, Part.ValueFormat) then
        Part.Kind := TPartKind.Formatted
      else
      begin
        Part.UnknownMacro := True;
        Part.TextSlot := FDefinitionStrings.AddText(FDefinitionLayout,
          Copy(Line, Index + 1, CloseParen - Index));
      end;

      if Part.Kind <> TPartKind.Text then
      begin
        Definition := Copy(Line, OpenParen + 1, CloseParen - OpenParen - 1);
        // A hit target may consume the first ')' as part of the value. Validate
        // the complete expression before resolving a shared helper by its name.
        Part.Expression := ParseExpression(Definition, Copy(Line, OpenParen + 1), Part.PreparedExpression);
      end;
      Parts.Add(Part);
      Index := CloseParen + 1;
    end;
    Result := Parts.ToArray;
  finally
    Parts.Free;
  end;
end;

function TRARichPresence.ParseExpression(const Name, Text: string; out Prepared: TExpression): TExpression;
var
  Candidate: TExpression;
  Key: string;

  procedure KeepExpression;
  begin
    Key := Name;
    if FExpressions.ContainsKey(Key) then
      Key := Key + #0 + IntToStr(FExpressions.Count);
    FExpressions.Add(Key, Candidate);
    Result := Candidate;
    Candidate := nil;
  end;

begin
  Prepared := nil;
  Result := nil;
  Candidate := TExpression.Create(Text);
  try
    if Candidate.Evaluator.IsRCSimpleValue then
    begin
      Key := Name + #0 + Candidate.CompiledDefinition;
      if not FSimpleExpressions.TryGetValue(Key, Result) then
      begin
        var CacheKey := Key;
        KeepExpression;
        FSimpleExpressions.Add(CacheKey, Result);
      end;
    end
    else
    begin
      for var Variable in FRCVariables do
        if FDefinitionStrings.GetText(Variable.NameSlot) = Name then
        begin
          Result := Variable;
          Break;
        end;
      if Result = nil then
      begin
        Candidate.NameSlot := FDefinitionStrings.AddText(FDefinitionLayout, Name);
        FDefinitionLayout.AddValue;
        Candidate.Evaluator.MeasureDefinitionLayout(FDefinitionLayout);
        KeepExpression;
        FRCVariables.Add(Result);
      end
      else if Candidate.CompiledDefinition <> Result.CompiledDefinition then
      begin
        // C copies every preparse's memory references even when it reuses the
        // first helper with this name. Preserve that graph without updating a
        // second helper state during frames or serializing it as a variable.
        if not FPreparedExpressions.TryGetValue(Candidate.CompiledDefinition, Prepared) then
        begin
          FPreparedExpressions.Add(Candidate.CompiledDefinition, Candidate);
          Prepared := Candidate;
          Candidate := nil;
        end;
      end;
    end;
    if Prepared = nil then
      Prepared := Result;
  finally
    Candidate.Free;
  end;
end;

function TRARichPresence.FindMacro(const Name: string; out Macro: TMacro): Boolean;
begin
  // Parsing display text can unescape a string also used as a lookup name.
  // Resolve against the current interned text, preserving declaration order.
  for var Candidate in FMacroOrder do
    if FDefinitionStrings.GetText(Candidate.NameSlot) = Name then
    begin
      Macro := Candidate;
      Exit(True);
    end;
  Macro := nil;
  Result := False;
end;

procedure TRARichPresence.ResolveDefinitionStrings;
begin
  // The C parser shares writable strings across labels, names and text parts.
  // Freeze their final contents only after every display has been parsed.
  for var Macro in FMacroOrder do
  begin
    Macro.DefaultText := FDefinitionStrings.GetText(Macro.DefaultTextSlot);
    if Macro.Ranges <> nil then
      for var Index := 0 to Macro.Ranges.Count - 1 do
      begin
        var Range := Macro.Ranges[Index];
        Range.Text := FDefinitionStrings.GetText(Range.TextSlot);
        Macro.Ranges[Index] := Range;
      end;
  end;
  for var Display in FDisplays do
    for var Index := 0 to Length(Display.Parts) - 1 do
      if Display.Parts[Index].Kind = TPartKind.Text then
      begin
        var Part := Display.Parts[Index];
        Part.Text := FDefinitionStrings.GetText(Part.TextSlot);
        if Part.UnknownMacro then
          Part.Text := '[Unknown macro]' + Part.Text;
        Display.Parts[Index] := Part;
      end;
  for var Variable in FRCVariables do
    Variable.NameHash := RADJB2(UTF8String(FDefinitionStrings.GetText(Variable.NameSlot)));
end;

procedure TRARichPresence.ParseDisplay(const Line: string; Conditional: Boolean);
var
  Entry: TDisplay;
  Delimiter: Integer;
begin
  Delimiter := 0;
  if Conditional then
  begin
    Delimiter := PosEx('?', Line, 2);
    if Delimiter = 0 then
      Exit;
  end;
  Entry := TDisplay.Create;
  FDisplays.Add(Entry);
  FDefinitionLayout.AddDisplay;
  Entry.Parts := ParseParts(Copy(Line, Delimiter + 1));
  if Conditional then
  begin
    Entry.Condition := TRATrigger.Create(TRATriggerDefinition.Parse(Copy(Line, 2, Delimiter - 2)));
    Entry.HasRequiredHits := Entry.Condition.HasRCRequiredHits;
    Entry.Condition.MeasureDefinitionLayout(FDefinitionLayout);
  end;
end;

constructor TRARichPresence.Create(const Script: string);
var
  ErrorLine: Integer;
begin
  inherited Create;
  FMacros := TObjectDictionary<string, TMacro>.Create([doOwnsValues]);
  FMacroOrder := TList<TMacro>.Create;
  FExpressions := TObjectDictionary<string, TExpression>.Create([doOwnsValues]);
  FSimpleExpressions := TDictionary<string, TExpression>.Create;
  FPreparedExpressions := TObjectDictionary<string, TExpression>.Create([doOwnsValues]);
  FDisplays := TObjectList<TDisplay>.Create;
  FRCVariables := TList<TExpression>.Create;
  FDefinitionLayout := TRADefinitionLayout.Create(TRADefinitionKind.RichPresence);
  FDefinitionStrings := TRADefinitionStrings.Create;
  try
    try
      ParseScript(RARichPresenceScriptPrefix(Script), ErrorLine);
      ResolveDefinitionStrings;
    finally
      FreeAndNil(FDefinitionStrings);
    end;
  except
    on E: ERAConditionError do
      raise ERARichPresenceError.CreateAtLine(E, ErrorLine);
  end;
end;

procedure TRARichPresence.ParseScript(const Script: string; out ErrorLine: Integer);
var
  Lines: TArray<string>;
  DisplayIndex, Index, LineCount: Integer;
  Line, Name: string;
  Macro: TMacro;
  IsLookup: Boolean;
begin
  ErrorLine := 1;
  Lines := Script.Split([#10]);
  LineCount := Length(Lines);
  if Script.EndsWith(#10) then
    Dec(LineCount);
  DisplayIndex := -1;
  Index := 0;
  while Index < LineCount do
  begin
    ErrorLine := Index + 1;
    Line := ReadScriptLine(Lines[Index]);
    IsLookup := Line.StartsWith('Lookup:');
    if IsLookup or Line.StartsWith('Format:') then
    begin
      Name := Line.Substring(7);
      Inc(Index);
      if (Name = 'Unformatted') and not IsLookup then
      begin
        ErrorLine := Index + 1;
        Inc(Index);
        Continue;
      end;
      Macro := TMacro.Create;
      try
        FDefinitionLayout.AddLookup;
        Macro.NameSlot := FDefinitionStrings.AddText(FDefinitionLayout, Name);
        if IsLookup then
        begin
          Macro.Kind := TPartKind.Lookup;
          Macro.Ranges := TList<TRange>.Create;
          while Index < LineCount do
          begin
            ErrorLine := Index + 1;
            if Lines[Index].StartsWith('//') then
            begin
              Inc(Index);
              Continue;
            end;
            Line := ReadScriptLine(Lines[Index]);
            if Length(Line) < 2 then
              Break;
            ParseLookupLine(Macro, Line, FDefinitionLayout, FDefinitionStrings);
            Inc(Index);
          end;
          if Index = LineCount then
            ErrorLine := Index + 1;
          Macro.BalanceRanges;
        end
        else
        begin
          Macro.Kind := TPartKind.Formatted;
          ErrorLine := Index + 1;
          if Index < LineCount then
          begin
            Line := ReadScriptLine(Lines[Index]);
            if Line.StartsWith('FormatType=') then
              Macro.ValueFormat := ParseRAFormat(Line.Substring(11));
          end;
        end;
        if not FMacros.ContainsKey(Name) then
        begin
          FMacros.Add(Name, Macro);
          FMacroOrder.Add(Macro);
          Macro := nil;
        end;
      finally
        Macro.Free;
      end;
    end
    else if Line.StartsWith('Display:') then
    begin
      DisplayIndex := Index + 1;
      repeat
        Inc(Index);
      until (Index >= LineCount) or
          (not Lines[Index].StartsWith('?') and not Lines[Index].StartsWith('//'));
    end;
    Inc(Index);
  end;

  FDefinitionLinesRead := LineCount;
  if ErrorLine > FDefinitionLinesRead then
    FDefinitionLinesRead := ErrorLine;
  Index := DisplayIndex;
  if Index >= 0 then
  begin
    while Index < LineCount do
    begin
      ErrorLine := Index + 1;
      if not Lines[Index].StartsWith('//') then
      begin
        Line := ReadScriptLine(Lines[Index]);
        ParseDisplay(Line, Line.StartsWith('?'));
        if not Line.StartsWith('?') then
          Exit;
      end;
      Inc(Index);
    end;
    // The parser reaches the line after the final conditional or comment.
    ErrorLine := Index + 1;
  end;
  raise ERAConditionError.CreateWithCode('Missing default Rich Presence display', RAErrorMissingDisplayString);
end;

destructor TRARichPresence.Destroy;
begin
  FDefinitionStrings.Free;
  FRCVariables.Free;
  FDisplays.Free;
  FSimpleExpressions.Free;
  FPreparedExpressions.Free;
  FExpressions.Free;
  FMacroOrder.Free;
  FMacros.Free;
  inherited;
end;

function TRARichPresence.GetDefinitionLayout: TRADefinitionLayout;
begin
  Result := FDefinitionLayout;
end;

procedure TRARichPresence.UpdateFrame(const ReadMemory: TRAMemoryRead);
begin
  for var Expression in FExpressions.Values do
    Expression.Evaluator.Evaluate(ReadMemory);

  for var Display in FDisplays do
    if (Display.Condition <> nil) and (Display.Condition.State <> TRATriggerState.Disabled) then
    begin
      if not Display.Condition.UpdateMemory(ReadMemory) then
        Display.Condition.Disable
      else if Display.HasRequiredHits then
        Display.Condition.TestPreparedFrame;
    end;
  FConditionsPrepared := True;
end;

function TRARichPresence.RenderDisplay(EvaluateConditions: Boolean): string;
var
  Matches: Boolean;
begin
  for var Display in FDisplays do
  begin
    if Display.Condition = nil then
      Exit(Display.Render);
    if Display.HasRequiredHits then
      Matches := Display.Condition.State = TRATriggerState.Triggered
    else if EvaluateConditions then
    begin
      if not FConditionsPrepared then
        Display.Condition.RefreshStoredValues;
      Matches := Display.Condition.TestPreparedFrame;
    end
    else
      Matches := Display.Condition.TestStoredFrame;
    if Matches then
      Exit(Display.Render);
  end;
  Result := '';
end;

function TRARichPresence.GetDisplayString: string;
begin
  Result := RenderDisplay(True);
end;

function TRARichPresence.GetDisplayString(Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt;
begin
  Result := CopyRAUTF8Text(GetDisplayString, Buffer, BufferSize);
end;

function TRARichPresence.PreviewDisplayString: string;
begin
  Result := RenderDisplay(False);
end;

function TRARichPresence.EvaluateFrame(const ReadMemory: TRAMemoryRead): string;
begin
  UpdateFrame(ReadMemory);
  Result := GetDisplayString;
end;

function TRARichPresence.EvaluateFrame(const ReadMemory: TRAMemoryRead; Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt;
begin
  UpdateFrame(ReadMemory);
  Result := GetDisplayString(Buffer, BufferSize);
end;

procedure TRARichPresence.Reset;
begin
  for var Expression in FExpressions.Values do
  begin
    Expression.Evaluator.Reset;
    Expression.Evaluator.RestoreRCDisplayValue;
  end;
  for var Display in FDisplays do
    if Display.Condition <> nil then
      Display.Condition.Reset;
end;

procedure TRARichPresence.ClearProgress;
begin
  for var Expression in FExpressions.Values do
  begin
    Expression.Evaluator.ClearProgress;
    Expression.Evaluator.RestoreRCDisplayValue;
  end;
  FConditionsPrepared := False;
  for var Display in FDisplays do
    if Display.Condition <> nil then
      Display.Condition.ClearProgress;
end;

procedure TRARichPresence.WriteProgress(const IO: TRAProgressIO);
begin
  IO.WriteUInt(FExpressions.Count);
  for var Expression in FExpressions do
  begin
    IO.WriteString(Expression.Key);
    Expression.Value.Evaluator.WriteProgress(IO);
  end;
  IO.WriteUInt(FDisplays.Count);
  for var Display in FDisplays do
    if Display.Condition <> nil then
      Display.Condition.WriteProgress(IO);
end;

procedure TRARichPresence.ReadProgress(const IO: TRAProgressIO);
var
  Expression: TExpression;
  Seen: TDictionary<string, Boolean>;
  Key: string;
begin
  IO.ExpectUInt(FExpressions.Count);
  Seen := TDictionary<string, Boolean>.Create;
  try
    for var Index := 0 to FExpressions.Count - 1 do
    begin
      Key := IO.ReadString;
      if Seen.ContainsKey(Key) or not FExpressions.TryGetValue(Key, Expression) then
        raise ERAProgressError.Create('Incompatible RetroAchievements Rich Presence expression');
      Seen.Add(Key, True);
      Expression.Evaluator.ReadProgress(IO);
    end;
  finally
    Seen.Free;
  end;
  IO.ExpectUInt(FDisplays.Count);
  for var Display in FDisplays do
    if Display.Condition <> nil then
      Display.Condition.ReadProgress(IO);
  FConditionsPrepared := False;
end;

end.

